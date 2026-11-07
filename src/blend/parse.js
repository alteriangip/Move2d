// Minimal .blend reader: file blocks + SDNA, with typed field access.
// Handles Blender 2.8 to 5.x files, 64-bit little-endian, plain, zstd- or gzip-compressed.
import { decompress as zstd } from 'fzstd';
import { gunzipSync } from 'three/addons/libs/fflate.module.js';

const td = new TextDecoder('utf-8');

export function parseBlend(input) {
  let bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (bytes[0] === 0x28 && bytes[1] === 0xb5 && bytes[2] === 0x2f && bytes[3] === 0xfd) bytes = zstd(bytes);
  else if (bytes[0] === 0x1f && bytes[1] === 0x8b) bytes = gunzipSync(bytes);
  const magic = td.decode(bytes.subarray(0, 7));
  if (magic !== 'BLENDER') throw new Error('This is not a .blend file.');
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  let pos, ptrSize, little, version, large;
  if (bytes[7] === 0x5f || bytes[7] === 0x2d) { // classic 12-byte header: BLENDER-v403
    ptrSize = bytes[7] === 0x5f ? 4 : 8; little = bytes[8] === 0x76; version = +td.decode(bytes.subarray(9, 12)); pos = 12; large = false;
  } else { // Blender 5 header: BLENDER17-01v0502
    const hlen = +td.decode(bytes.subarray(7, 9));
    ptrSize = 8; little = bytes[12] === 0x76; version = +td.decode(bytes.subarray(13, 17)); pos = hlen; large = true;
  }
  if (!little) throw new Error('Big-endian .blend files are not supported.');
  if (ptrSize !== 8) throw new Error('32-bit .blend files are not supported.');

  const u64 = o => dv.getUint32(o, true) + dv.getUint32(o + 4, true) * 4294967296;
  const blocks = [];
  let dnaBlock = null, owner = -1;
  const NON_ID = new Set(['DATA', 'REND', 'TEST', 'GLOB', 'USER', 'DNA1', 'ENDB']);
  while (pos + 16 <= bytes.length) {
    const code = td.decode(bytes.subarray(pos, pos + 4)).replace(/\0+$/, '');
    let len, old, sdna, nr, head;
    if (large) { sdna = dv.getInt32(pos + 4, true); old = dv.getBigUint64(pos + 8, true); len = u64(pos + 16); nr = u64(pos + 24); head = 32; }
    else { len = dv.getInt32(pos + 4, true); old = dv.getBigUint64(pos + 8, true); sdna = dv.getInt32(pos + 16, true); nr = dv.getInt32(pos + 20, true); head = 24; }
    const b = { code, len, old, sdna, nr, off: pos + head };
    if (code === 'ENDB') break;
    if (!NON_ID.has(code)) owner = blocks.length;
    b.owner = NON_ID.has(code) ? owner : blocks.length;
    if (code === 'DNA1') dnaBlock = b; else blocks.push(b);
    pos += head + len;
  }
  if (!dnaBlock) throw new Error('The .blend file has no type information (DNA1 block).');
  const dna = readDNA(bytes, dv, dnaBlock.off, ptrSize);
  // Blender 5 reuses pointer values between data-blocks, so keep every candidate.
  const byPtr = new Map();
  for (const b of blocks) { const l = byPtr.get(b.old); if (l) l.push(b); else byPtr.set(b.old, [b]); }
  return new BlendFile(bytes, dv, blocks, byPtr, dna, ptrSize, version);
}

function readDNA(bytes, dv, p, ptrSize) {
  const base = p;
  const tag = () => { const t = td.decode(bytes.subarray(p, p + 4)); p += 4; return t; };
  const align = () => { p = base + ((p - base + 3) & ~3); };
  const strings = n => { const out = []; for (let i = 0; i < n; i++) { let e = p; while (bytes[e]) e++; out.push(td.decode(bytes.subarray(p, e))); p = e + 1; } return out; };
  if (tag() !== 'SDNA') throw new Error('Bad DNA');
  tag(); const names = strings(dv.getInt32((p += 4) - 4, true)); align();
  tag(); const types = strings(dv.getInt32((p += 4) - 4, true)); align();
  tag(); const tlen = []; for (let i = 0; i < types.length; i++) { tlen.push(dv.getInt16(p, true)); p += 2; } align();
  tag(); const nStruct = dv.getInt32(p, true); p += 4;
  const structs = []; const structByType = new Map();
  for (let i = 0; i < nStruct; i++) {
    const type = dv.getInt16(p, true), nf = dv.getInt16(p + 2, true); p += 4;
    const fields = new Map(); let off = 0;
    for (let f = 0; f < nf; f++) {
      const ft = dv.getInt16(p, true), fn = names[dv.getInt16(p + 2, true)]; p += 4;
      const isPtr = fn.startsWith('*') || fn.startsWith('(*');
      const dims = [...fn.matchAll(/\[(\d+)\]/g)].map(m => +m[1]);
      const count = dims.reduce((a, b) => a * b, 1);
      const elem = isPtr ? ptrSize : tlen[ft];
      const clean = fn.replace(/^\(?\*+/, '').replace(/\)\(.*$/, '').replace(/\[.*$/, '');
      fields.set(clean, { type: types[ft], isPtr, isPtrPtr: fn.startsWith('**'), dims, count, elem, off, size: elem * count });
      off += elem * count;
    }
    const s = { name: types[type], size: tlen[type], fields };
    structs.push(s); structByType.set(s.name, s);
  }
  return { names, types, tlen, structs, structByType };
}

const PRIM = { char: 'u8', uchar: 'u8', int8_t: 'i8', short: 'i16', ushort: 'u16', int: 'i32', uint: 'u32', int32_t: 'i32', uint32_t: 'u32', float: 'f32', double: 'f64', int64_t: 'i64', uint64_t: 'u64', long: 'i32', ulong: 'u32', bool: 'u8', uint8_t: 'u8', int16_t: 'i16', uint16_t: 'u16' };

export class BlendFile {
  constructor(bytes, dv, blocks, byPtr, dna, ptrSize, version) { Object.assign(this, { bytes, dv, blocks, byPtr, dna, ptrSize, version }); }

  view(off, typeName, owner = -1) { const s = this.dna.structByType.get(typeName); if (!s) throw new Error('Unknown struct ' + typeName); return new SV(this, off, s, owner); }
  /** View of the struct a block holds (its SDNA type), element i. */
  blockView(b, i = 0) { const s = this.dna.structs[b.sdna]; return new SV(this, b.off + i * s.size, s, b.owner); }
  /** Resolve a pointer. `owner`: the data-block the pointer was read from; `ftype`: the field's pointed-to type. */
  deref(ptr, owner = -1, ftype = null) {
    if (!ptr) return null;
    const l = this.byPtr.get(BigInt(ptr));
    if (!l) return null;
    if (l.length === 1) return l[0];
    let best = l[0], bestScore = -1;
    for (const b of l) {
      const st = this.dna.structs[b.sdna]?.name;
      let score = 0;
      if (ftype === 'ID') score += b.code !== 'DATA' ? 2 : 0;
      else if (ftype && ftype !== 'void' && ftype !== 'char') score += st === ftype ? 2 : 0;
      if (b.owner === owner) score += 1;
      if (score > bestScore) { best = b; bestScore = score; }
    }
    return best;
  }
  get(ptr, typeName, owner = -1, ftype = typeName) { const b = this.deref(ptr, owner, ftype); if (!b) return null; return typeName ? this.view(b.off, typeName, b.owner) : this.blockView(b); }
  ofCode(code) { return this.blocks.filter(b => b.code === code); }
  /** Walk a ListBase {first, last}. */
  *list(lb, typeName) {
    let p = lb.ptr('first'), owner = lb.owner; const seen = new Set();
    while (p && !seen.has(p)) {
      seen.add(p);
      const b = this.deref(p, owner, typeName || null); if (!b) return;
      const v = typeName ? this.view(b.off, typeName, b.owner) : this.blockView(b);
      yield v;
      // Derived structs (e.g. ArmatureModifierData) start with their base struct, which holds `next`.
      const base = v.has('next') ? v : v.sub(v.s.fields.keys().next().value);
      p = base.ptr('next'); owner = v.owner;
    }
  }
}

class SV {
  constructor(file, off, s, owner = -1) { this.file = file; this.off = off; this.s = s; this.owner = owner; }
  /** Follow a pointer field. */
  blk(name) { const f = this.field(name); return this.file.deref(this.ptr(name), this.owner, f.isPtrPtr ? null : f.type); }
  get(name, typeName) { const b = this.blk(name); if (!b) return null; return typeName ? this.file.view(b.off, typeName, b.owner) : this.file.blockView(b); }
  raw(name) { const b = this.blk(name); return b ? this.file.bytes.subarray(b.off, b.off + b.len) : null; }
  f32(name, n) { const b = this.blk(name); if (!b) return null; const dv = this.file.dv, out = new Float32Array(n); for (let i = 0; i < n && i * 4 + 4 <= b.len; i++) out[i] = dv.getFloat32(b.off + i * 4, true); return out; }
  i32(name, n) { const b = this.blk(name); if (!b) return null; const dv = this.file.dv, out = new Int32Array(n); for (let i = 0; i < n && i * 4 + 4 <= b.len; i++) out[i] = dv.getInt32(b.off + i * 4, true); return out; }
  get type() { return this.s.name; }
  has(name) { return this.s.fields.has(name); }
  field(name) { const f = this.s.fields.get(name); if (!f) throw new Error(`${this.s.name} has no field ${name}`); return f; }
  ptr(name, i = 0) { const f = this.field(name); return this.file.dv.getBigUint64(this.off + f.off + i * this.file.ptrSize, true); }
  num(name, i = 0) {
    const f = this.field(name), dv = this.file.dv, o = this.off + f.off + i * f.elem;
    switch (PRIM[f.type]) {
      case 'u8': return dv.getUint8(o); case 'i8': return dv.getInt8(o);
      case 'i16': return dv.getInt16(o, true); case 'u16': return dv.getUint16(o, true);
      case 'i32': return dv.getInt32(o, true); case 'u32': return dv.getUint32(o, true);
      case 'f32': return dv.getFloat32(o, true); case 'f64': return dv.getFloat64(o, true);
      case 'i64': case 'u64': return dv.getUint32(o, true) + dv.getInt32(o + 4, true) * 4294967296;
      default: throw new Error(`${this.s.name}.${name} is ${f.type}, not a number`);
    }
  }
  nums(name) { const f = this.field(name); return Array.from({ length: f.count }, (_, i) => this.num(name, i)); }
  str(name) { const f = this.field(name); const b = this.file.bytes.subarray(this.off + f.off, this.off + f.off + f.size); const e = b.indexOf(0); return td.decode(e < 0 ? b : b.subarray(0, e)); }
  sub(name) { const f = this.field(name); return this.file.view(this.off + f.off, f.type); }
  /** first available of several field names (DNA renames across versions) */
  pick(...names) { return names.find(n => this.has(n)); }
}

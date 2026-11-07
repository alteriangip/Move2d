// Build a skinned three.js character from a parsed .blend:
// the main armature's deform bones (re-linked like tools/blend_to_glb.py), the meshes skinned to it,
// UVs, vertex weights, shape keys and base-colour textures packed in the file.
import * as THREE from 'three';
import { parseBlend } from './parse.js';

const OB_MESH = 1, OB_ARMATURE = 25, MOD_ARMATURE = 8, BONE_NO_DEFORM = 1 << 12, HIDE_VIEWPORT = 1;
const td = new TextDecoder('utf-8');
const idName = v => v.sub('id').str('name').slice(2);

/** Read the file and list what can be exported (for a picker UI). */
export function inspectBlend(buffer) {
  const f = parseBlend(buffer);
  const objects = f.ofCode('OB').map(b => f.blockView(b));
  const armatureOf = ob => {
    for (const md of f.list(ob.sub('modifiers'))) {
      if (md.type === 'ArmatureModifierData' || (md.has('type') && md.num('type') === MOD_ARMATURE && md.type !== 'ModifierData')) {
        const p = md.ptr('object'); if (p) return md.blk('object');
      }
    }
    return null;
  };
  const skinned = objects.filter(o => o.num('type') === OB_MESH).map(o => ({ ob: o, arm: armatureOf(o) })).filter(x => x.arm);
  const counts = new Map();
  for (const s of skinned) counts.set(s.arm, (counts.get(s.arm) || 0) + 1);
  if (!counts.size) throw new Error('No meshes in this file are attached to an armature, so there is nothing to pose.');
  const armPtr = [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0];
  const arm = f.blockView(armPtr);
  const meshes = skinned.filter(s => s.arm === armPtr).map(s => {
    const me = s.ob.get('data', 'Mesh');
    return { name: idName(s.ob), hidden: !!(s.ob.num('restrictflag') & HIDE_VIEWPORT), verts: me.num('totvert'), faces: me.num('totpoly'), ob: s.ob };
  });
  return { file: f, version: f.version, armature: { name: idName(arm), ob: arm }, meshes };
}

/** Build the scene. `include`: names of meshes to use (default: the ones visible in the file). */
export async function blendToThree(buffer, { include, textures = true, onProgress } = {}) {
  const info = buffer.file ? buffer : inspectBlend(buffer);
  const f = info.file;
  const step = (t) => onProgress && onProgress(t);
  const use = info.meshes.filter(m => include ? include.includes(m.name) : !m.hidden);
  if (!use.length) throw new Error('No meshes selected.');

  // --- object transforms (Blender is Z-up; the root turns it Y-up) ---
  const worldCache = new Map();
  function world(ob) {
    if (worldCache.has(ob.off)) return worldCache.get(ob.off);
    const local = new THREE.Matrix4();
    const loc = new THREE.Vector3(...ob.nums('loc'));
    const scale = new THREE.Vector3(...ob.nums(ob.pick('size', 'scale')));
    const mode = ob.num('rotmode');
    const q = new THREE.Quaternion();
    if (mode === 0) { const w = ob.nums('quat'); q.set(w[1], w[2], w[3], w[0]).normalize(); }
    else if (mode === -1) { const ax = new THREE.Vector3(...ob.nums('rotAxis')).normalize(); q.setFromAxisAngle(ax, ob.num('rotAngle')); }
    else { const order = ['XYZ', 'XZY', 'YXZ', 'YZX', 'ZXY', 'ZYX'][mode - 1] || 'XYZ'; q.setFromEuler(new THREE.Euler(...ob.nums('rot'), order.split('').reverse().join(''))); }
    local.compose(loc, q, scale);
    let m = local;
    const pp = ob.ptr('parent');
    if (pp) { const parent = ob.get('parent', 'Object'); m = world(parent).clone().multiply(new THREE.Matrix4().fromArray(ob.nums('parentinv'))).multiply(local); }
    worldCache.set(ob.off, m);
    return m;
  }

  // --- bones ---
  step('Reading skeleton');
  const armOb = info.armature.ob;
  const armData = armOb.get('data', 'bArmature');
  const all = [];
  const walk = (lb, parent) => { for (const b of f.list(lb, 'Bone')) { const rec = { name: b.str('name'), deform: !(b.num('flag') & BONE_NO_DEFORM), mat: new THREE.Matrix4().fromArray(b.nums('arm_mat')), parent }; all.push(rec); walk(b.sub('childbase'), rec); } };
  walk(armData.sub('bonebase'), null);
  const byName = new Map(all.map(b => [b.name, b]));
  const twin = n => { for (const pre of ['ORG-', 'ORG_', 'MCH-']) if (n.startsWith(pre)) for (const d of ['DEF-', 'DEF_']) { const t = byName.get(d + n.slice(pre.length)); if (t && t.deform) return t; } return null; };
  const deform = all.filter(b => b.deform);
  for (const b of deform) {
    let p = b.parent, target = null;
    while (p && !target) { target = p.deform ? p : twin(p.name); if (target === b) target = null; p = p.parent; }
    b.dparent = target;
  }
  const armWorld = world(armOb);
  const root = new THREE.Group(); root.name = info.armature.name + ' (Move2D)';
  root.rotation.x = -Math.PI / 2;
  const armNode = new THREE.Object3D(); armNode.name = info.armature.name;
  armWorld.decompose(armNode.position, armNode.quaternion, armNode.scale);
  root.add(armNode);
  const bones = deform.map(b => { const bone = new THREE.Bone(); bone.name = b.name; b.node = bone; return bone; });
  for (const b of deform) {
    const local = b.dparent ? b.dparent.mat.clone().invert().multiply(b.mat) : b.mat.clone();
    local.decompose(b.node.position, b.node.quaternion, b.node.scale);
    (b.dparent ? b.dparent.node : armNode).add(b.node);
  }
  root.updateMatrixWorld(true);
  const skeleton = new THREE.Skeleton(bones);
  const boneIndex = new Map(deform.map((b, i) => [b.name, i]));

  // --- materials ---
  const texCache = new Map();
  const matCache = new Map();
  async function texture(img) {
    if (!textures || typeof document === 'undefined') return null;
    if (texCache.has(img.off)) return texCache.get(img.off);
    const p = (async () => {
      let pf = null;
      if (img.has('packedfiles')) for (const ipf of f.list(img.sub('packedfiles'), 'ImagePackedFile')) { pf = ipf.get('packedfile', 'PackedFile'); if (pf) break; }
      if (!pf && img.has('packedfile')) pf = img.get('packedfile', 'PackedFile');
      if (!pf) return null;
      const bytes = pf.raw('data');
      if (!bytes) return null;
      const url = URL.createObjectURL(new Blob([bytes.slice(0, pf.num('size'))]));
      try {
        const el = new Image(); el.src = url; await el.decode();
        const t = new THREE.Texture(el); t.colorSpace = THREE.SRGBColorSpace; t.wrapS = t.wrapT = THREE.RepeatWrapping; t.name = idName(img); t.needsUpdate = true;
        return t;
      } catch { return null; } finally { setTimeout(() => URL.revokeObjectURL(url), 1000); }
    })();
    texCache.set(img.off, p);
    return p;
  }
  function imagesIn(tree, seen = new Set(), out = []) {
    if (!tree || seen.has(tree.off)) return out;
    seen.add(tree.off);
    for (const n of f.list(tree.sub('nodes'), 'bNode')) {
      const target = n.blk('id'); if (!target) continue;
      if (target.code === 'IM') out.push(f.blockView(target));
      else if (target.code === 'NT') imagesIn(f.blockView(target), seen, out);
    }
    return out;
  }
  function pickBase(imgs) {
    const named = imgs.map(i => [i, idName(i).toLowerCase()]);
    const skip = ['matcap', 'lightmap', 'ramp', '_n.', '_n_', '_m.', '_a.', 'normal'];
    return (named.find(([, n]) => /_d(\.|$)/.test(n) || n.includes('_d.') || n.includes('diffuse') || n.includes('albedo') || n.includes('basecolor')) ||
      named.find(([, n]) => !skip.some(s => n.includes(s))) || [])[0] || null;
  }
  async function material(block) {
    const key = block ? block.off : -1;
    if (matCache.has(key)) return matCache.get(key);
    const ma = block ? f.blockView(block) : null;
    const m = new THREE.MeshStandardMaterial({ roughness: 0.85, metalness: 0, side: THREE.DoubleSide });
    if (ma) {
      m.name = idName(ma);
      if (ma.has('r')) m.color.setRGB(ma.num('r'), ma.num('g'), ma.num('b'), THREE.SRGBColorSpace);
      const tree = ma.has('nodetree') ? ma.get('nodetree', 'bNodeTree') : null;
      const img = tree ? pickBase(imagesIn(tree)) : null;
      const t = img ? await texture(img) : null;
      if (t) { m.map = t; m.color.set(0xffffff); }
    }
    matCache.set(key, m);
    return m;
  }

  // --- meshes ---
  for (const [mi, entry] of use.entries()) {
    step(`Building ${entry.name} (${mi + 1}/${use.length})`);
    const ob = entry.ob, me = ob.get('data', 'Mesh');
    const a = meshAttributes(f, me);
    const nv = me.num('totvert'), nf = me.num('totpoly');
    // group names
    let groups = [...f.list(me.sub('vertex_group_names'), 'bDeformGroup')].map(g => g.str('name'));
    if (!groups.length && ob.has('defbase')) groups = [...f.list(ob.sub('defbase'), 'bDeformGroup')].map(g => g.str('name'));
    const groupToBone = groups.map(n => boneIndex.has(n) ? boneIndex.get(n) : -1);

    // per-vertex top-4 weights
    const sIdx = new Uint16Array(nv * 4), sW = new Float32Array(nv * 4);
    if (a.dvert) for (let v = 0; v < nv; v++) {
      const list = a.dvert[v]; if (!list) continue;
      const ws = []; for (const [g, w] of list) { const bi = groupToBone[g]; if (bi >= 0 && w > 0) ws.push([bi, w]); }
      ws.sort((x, y) => y[1] - x[1]);
      const top = ws.slice(0, 4); const sum = top.reduce((s, x) => s + x[1], 0) || 1;
      top.forEach(([bi, w], k) => { sIdx[v * 4 + k] = bi; sW[v * 4 + k] = w / sum; });
    }
    // shape keys
    const keys = [];
    const key = me.get('key', 'Key');
    if (key) {
      const blocks = [...f.list(key.sub('block'), 'KeyBlock')];
      const basis = blocks[0];
      const base = basis && basis.f32('data', nv * 3);
      for (const kb of blocks.slice(1)) {
        if (kb.num('totelem') !== nv) continue;
        const d = kb.f32('data', nv * 3); if (!d || !base) continue;
        let any = false; for (let i = 0; i < d.length; i++) { d[i] -= base[i]; if (!any && Math.abs(d[i]) > 1e-7) any = true; }
        if (any) keys.push({ name: kb.str('name'), delta: d });
      }
    }
    // split vertices by UV, triangulate, group by material
    const map = new Map(); const srcV = []; const uvs = [];
    const tris = [];
    for (let fi = 0; fi < nf; fi++) {
      const s = a.faceOffsets[fi], e = a.faceOffsets[fi + 1];
      const corner = c => {
        const v = a.cornerVert[c];
        const u = a.uv ? a.uv[c * 2] : 0, w = a.uv ? a.uv[c * 2 + 1] : 0;
        const k = v + ',' + Math.round(u * 1e5) + ',' + Math.round(w * 1e5);
        let idx = map.get(k);
        if (idx === undefined) { idx = srcV.length; map.set(k, idx); srcV.push(v); uvs.push(u, w); }
        return idx;
      };
      const ids = []; for (let c = s; c < e; c++) ids.push(corner(c));
      const mat = a.matIndex ? a.matIndex[fi] : 0;
      for (let k = 1; k + 1 < ids.length; k++) tris.push(mat, ids[0], ids[k], ids[k + 1]);
    }
    // smooth normals per original vertex (no seams at UV splits)
    const vn = new Float32Array(nv * 3);
    const P = a.positions, tmpA = new THREE.Vector3(), tmpB = new THREE.Vector3(), tmpC = new THREE.Vector3();
    for (let t = 0; t < tris.length; t += 4) {
      const i0 = srcV[tris[t + 1]], i1 = srcV[tris[t + 2]], i2 = srcV[tris[t + 3]];
      tmpA.fromArray(P, i1 * 3).sub(tmpC.fromArray(P, i0 * 3));
      tmpB.fromArray(P, i2 * 3).sub(tmpC);
      tmpA.cross(tmpB);
      for (const i of [i0, i1, i2]) { vn[i * 3] += tmpA.x; vn[i * 3 + 1] += tmpA.y; vn[i * 3 + 2] += tmpA.z; }
    }
    const n = srcV.length;
    const pos = new Float32Array(n * 3), nor = new Float32Array(n * 3), si = new Uint16Array(n * 4), sw = new Float32Array(n * 4);
    for (let i = 0; i < n; i++) {
      const v = srcV[i];
      pos.set(P.subarray(v * 3, v * 3 + 3), i * 3);
      tmpA.fromArray(vn, v * 3).normalize(); nor.set([tmpA.x, tmpA.y, tmpA.z], i * 3);
      si.set(sIdx.subarray(v * 4, v * 4 + 4), i * 4); sw.set(sW.subarray(v * 4, v * 4 + 4), i * 4);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('normal', new THREE.BufferAttribute(nor, 3));
    if (a.uv) g.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(uvs), 2));
    g.setAttribute('skinIndex', new THREE.BufferAttribute(si, 4));
    g.setAttribute('skinWeight', new THREE.BufferAttribute(sw, 4));
    if (keys.length) {
      g.morphAttributes.position = keys.map(k => {
        const d = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) d.set(k.delta.subarray(srcV[i] * 3, srcV[i] * 3 + 3), i * 3);
        const attr = new THREE.BufferAttribute(d, 3); attr.name = k.name;
        return attr;
      });
      g.morphTargetsRelative = true;
    }
    // index sorted by material
    const order = [];
    for (let t = 0; t < tris.length; t += 4) order.push(t);
    order.sort((x, y) => tris[x] - tris[y]);
    const index = new Uint32Array(order.length * 3);
    let start = 0, cur = order.length ? tris[order[0]] : 0;
    const slots = [];
    order.forEach((t, k) => {
      if (tris[t] !== cur) { g.addGroup(start, k * 3 - start, slots.length); slots.push(cur); start = k * 3; cur = tris[t]; }
      index.set([tris[t + 1], tris[t + 2], tris[t + 3]], k * 3);
    });
    g.addGroup(start, index.length - start, slots.length); slots.push(cur);
    g.setIndex(new THREE.BufferAttribute(index, 1));
    g.computeBoundingBox(); g.computeBoundingSphere();

    const matPtrs = [];
    const totcol = me.num('totcol');
    const matBlock = me.blk('mat');
    for (let i = 0; i < totcol; i++) matPtrs.push(matBlock ? f.deref(f.dv.getBigUint64(matBlock.off + i * 8, true), me.owner, 'Material') : null);
    const mats = await Promise.all(slots.map(s => material(matPtrs[s] || null)));

    const mesh = new THREE.SkinnedMesh(g, mats.length === 1 ? mats[0] : mats);
    mesh.name = entry.name;
    if (keys.length) { g.userData.targetNames = keys.map(k => k.name); mesh.updateMorphTargets(); }
    world(ob).decompose(mesh.position, mesh.quaternion, mesh.scale);
    root.add(mesh);
    mesh.updateMatrixWorld(true);
    mesh.bind(skeleton, mesh.matrixWorld);
  }
  step('Done');
  return { root, skeleton, info: { version: f.version, armature: info.armature.name, bones: bones.length, meshes: use.map(m => m.name) } };
}

/** Vertex positions, corners, faces, UVs, material indices and weights, for 4.x and 5.x layouts. */
function meshAttributes(f, me) {
  const nv = me.num('totvert'), nl = me.num('totloop'), nf = me.num('totpoly');
  const out = { positions: null, cornerVert: null, uv: null, matIndex: null, dvert: null, faceOffsets: null };
  out.faceOffsets = me.has('poly_offset_indices') ? me.i32('poly_offset_indices', nf + 1) : null;
  if (!out.faceOffsets) throw new Error('This .blend was saved by a Blender older than 3.6. Open and re-save it in a newer Blender first.');

  const layerSize = f.dna.structByType.get('CustomDataLayer').size;
  const layers = (cdName) => {
    if (!me.has(cdName)) return [];
    const cd = me.sub(cdName), n = cd.num('totlayer'), b = cd.blk('layers');
    if (!b) return [];
    return Array.from({ length: n }, (_, i) => f.view(b.off + i * layerSize, 'CustomDataLayer', b.owner));
  };
  for (const l of layers('vdata')) {
    const t = l.num('type'), name = l.str('name');
    if (t === 48 && name === 'position') out.positions = l.f32('data', nv * 3);
    if (t === 2) out.dvert = readDvert(f, l.blk('data'), nv);
  }
  for (const l of layers('ldata')) {
    const t = l.num('type'), name = l.str('name');
    if (t === 11 && name === '.corner_vert') out.cornerVert = l.i32('data', nl);
    if (t === 49 && !name.startsWith('.') && !out.uv) out.uv = l.f32('data', nl * 2);
  }
  for (const l of layers('pdata')) if (l.num('type') === 11 && l.str('name') === 'material_index') out.matIndex = l.i32('data', nf);

  if (me.has('attribute_storage')) { // Blender 5
    const as = me.sub('attribute_storage');
    const b = as.blk('dna_attributes');
    const n = b ? Math.min(as.num('dna_attributes_num'), b.nr) : 0;
    for (let i = 0; i < n; i++) {
      const at = f.blockView(b, i);
      const nb = at.blk('name');
      const name = nb ? td.decode(f.bytes.subarray(nb.off, nb.off + nb.len)).replace(/\0[\s\S]*$/, '') : '';
      const type = at.num('data_type'), domain = at.num('domain'), storage = at.num('storage_type');
      const holder = at.get('data');
      if (!holder) continue;
      const count = [nv, me.num('totedge'), nf, nl][domain] || 0;
      const comps = { 3: 1, 6: 2, 7: 3 }[type];
      if (!comps) continue;
      const read = (sv, len) => type === 3 ? sv.i32('data', len) : sv.f32('data', len);
      let arr;
      if (storage === 0) arr = read(holder, count * comps);
      else { const one = read(holder, comps); arr = type === 3 ? new Int32Array(count * comps) : new Float32Array(count * comps); for (let k = 0; k < count; k++) arr.set(one, k * comps); }
      if (!arr) continue;
      if (name === 'position' && domain === 0 && type === 7) out.positions = arr;
      else if (name === '.corner_vert' && domain === 3 && type === 3) out.cornerVert = arr;
      else if (name === 'material_index' && domain === 2 && type === 3) out.matIndex = arr;
      else if (type === 6 && domain === 3 && !name.startsWith('.') && !out.uv) out.uv = arr;
    }
  }
  if (!out.positions || !out.cornerVert) throw new Error('Could not read the mesh data in this .blend.');
  return out;
}

function readDvert(f, b, nv) {
  if (!b) return null;
  const s = f.dna.structByType.get('MDeformVert');
  const out = new Array(nv);
  for (let v = 0; v < nv; v++) {
    const dv = f.view(b.off + v * s.size, 'MDeformVert', b.owner);
    const n = dv.num('totweight'); if (!n) continue;
    const wb = dv.blk('dw'); if (!wb) continue;
    const list = [];
    for (let k = 0; k < n; k++) list.push([f.dv.getInt32(wb.off + k * 8, true), f.dv.getFloat32(wb.off + k * 8 + 4, true)]);
    out[v] = list;
  }
  return out;
}

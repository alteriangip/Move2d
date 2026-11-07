// Humanoid rig detection and the pose math shared by presets, sliders, IK and animation.
//
// Character frame ("char"): x = the character's left, y = up, z = the way the character faces.
// Every preset pose is authored in that frame, so the same pose works on any rig whose bones we
// can name, whatever its bone axes, scale or rest pose (T-pose or A-pose).
import * as THREE from 'three';

export const FINGERS = ['thumb', 'index', 'middle', 'ring', 'little'];
const SIDED = ['shoulder', 'upperArm', 'lowerArm', 'hand', 'upperLeg', 'lowerLeg', 'foot', 'toes'];
const CENTRAL = ['hips', 'spine', 'chest', 'upperChest', 'neck', 'head'];

export const SLOTS = [
  ...CENTRAL,
  ...['L', 'R'].flatMap(s => SIDED.map(b => b + s)),
  ...['L', 'R'].flatMap(s => FINGERS.flatMap(f => [1, 2, 3].map(i => f + i + s))),
];

export const SLOT_LABEL = slot => {
  const m = slot.match(/^(.*?)([LR])?$/);
  const base = m[1].replace(/([A-Z])/g, ' $1').replace(/(\d)/, ' $1').toLowerCase();
  return (m[2] ? (m[2] === 'L' ? 'Left ' : 'Right ') : '') + base;
};

// ---- name normalisation -------------------------------------------------------------------
const FW = '０１２３４５６７８９';
const lower = s => s.replace(/[０-９]/g, c => String(FW.indexOf(c))).toLowerCase();

export function sideOf(name) {
  const n = lower(name);
  if (n.includes('左')) return 'L';
  if (n.includes('右')) return 'R';
  if (/left/.test(n)) return 'L';
  if (/right/.test(n)) return 'R';
  if (/(^|[^a-z])l([^a-z]|$)/.test(n)) return 'L';
  if (/(^|[^a-z])r([^a-z]|$)/.test(n)) return 'R';
  return '';
}

export function baseOf(name) {
  let n = lower(name);
  n = n.replace(/^.*[|:]/, ''); // mixamorig:Hips, Armature|Hips
  n = n.replace(/[左右]/g, '').replace(/left|right/g, '');
  n = n.replace(/(^|[^a-z])[lr](?=[^a-z]|$)/g, '$1');
  n = n.replace(/[\s_.\-]/g, '');
  // Strip rig prefixes, possibly stacked: "DEF-Bip001 Pelvis" -> "pelvis".
  for (let prev = ''; prev !== n;) { prev = n; n = n.replace(/^(mixamorig\d*|bip0*1|bip|jbipc|jbip|def|org|mch|ccbase|valvebipedbip01)/, ''); }
  return n;
}

const ALIASES = {
  hips: ['hips', 'pelvis', 'hip', '下半身', 'lowerbody'],
  spine: ['spine', '上半身', 'upperbody', 'spine01', 'abdomen', 'spine0'],
  chest: ['chest', 'spine1', '上半身2', 'upperbody2', 'spine02', 'spine001'],
  upperChest: ['upperchest', 'spine2', '上半身3', 'upperbody3', 'spine03', 'spine002'],
  neck: ['neck', '首', 'neck01', 'neck1'],
  head: ['head', '頭'],
  shoulder: ['shoulder', 'clavicle', '肩', 'collar', 'collarbone'],
  upperArm: ['upperarm', 'uparm', 'arm', '腕'],
  lowerArm: ['forearm', 'lowerarm', 'ひじ', '肘', 'elbow', 'loarm'],
  hand: ['hand', '手首', 'wrist'],
  upperLeg: ['thigh', 'upperleg', 'upleg', '足', 'legupper'],
  lowerLeg: ['calf', 'lowerleg', 'shin', 'knee', 'ひざ', '膝', 'leglower'],
  foot: ['foot', '足首', 'ankle'],
  toes: ['toe', 'toes', 'toebase', 'toe0', 'つま先', '足先ex', 'toe1'],
};
const FINGER_NAMES = {
  thumb: ['thumb', '親指'], index: ['index', '人指', '人差指', 'pointer'],
  middle: ['middle', '中指'], ring: ['ring', '薬指'], little: ['little', 'pinky', 'pinkie', '小指'],
};
FINGERS.forEach((f, k) => {
  for (let i = 1; i <= 3; i++) {
    const list = [];
    for (const n of FINGER_NAMES[f]) {
      if (/[^\x00-\x7f]/.test(n)) list.push(n + (f === 'thumb' ? i - 1 : i));
      else list.push(n + i, n + '0' + i, 'hand' + n + i, 'f' + n + '0' + i, 'f' + n + i, n + 'finger' + i,
        n + ['proximal', 'intermediate', 'distal'][i - 1]);
    }
    list.push('finger' + k + (i === 1 ? '' : i - 1)); // Bip001 L Finger0 / Finger01 / Finger02
    ALIASES[f + i] = list;
  }
});

const isTwist = b => /twist|roll|捩|ex$|_end$|end$|nub/i.test(b.name);

/** Map humanoid slots to bones. `overrides` (slot -> bone name) wins over detection. */
export function detectRig(bones, overrides = {}) {
  const byName = new Map(bones.map(b => [b.name, b]));
  const map = {};
  const index = new Map();
  for (const [slot, list] of Object.entries(ALIASES)) list.forEach(a => { if (!index.has(a)) index.set(a, slot); });
  const hasUpLeg = bones.some(b => baseOf(b.name) === 'upleg');

  for (const b of bones) {
    const base = baseOf(b.name);
    let slot = index.get(base);
    if (base === 'leg') slot = hasUpLeg ? 'lowerLeg' : 'upperLeg';
    if (!slot) continue;
    const side = sideOf(b.name);
    const key = CENTRAL.includes(slot) ? (side ? null : slot) : (side ? slot + side : null);
    if (key && !map[key]) map[key] = b;
  }

  // Fill gaps from the hierarchy: the first non-twist child of a known bone.
  const child = b => b && b.children.find(c => c.isBone && !isTwist(c));
  for (const s of ['L', 'R']) {
    map['lowerArm' + s] ||= child(map['upperArm' + s]);
    map['hand' + s] ||= child(map['lowerArm' + s]);
    map['lowerLeg' + s] ||= child(map['upperLeg' + s]);
    map['foot' + s] ||= child(map['lowerLeg' + s]);
    map['toes' + s] ||= child(map['foot' + s]);
  }
  map.head ||= child(map.neck);
  if (!map.hips && map.upperLegL && map.spine) {
    let p = map.spine.parent;
    while (p && p.isBone) { let q = map.upperLegL; while (q && q !== p) q = q.parent; if (q === p) { map.hips = p; break; } p = p.parent; }
  }
  for (const [slot, name] of Object.entries(overrides)) {
    if (name === '') delete map[slot];
    else if (byName.has(name)) map[slot] = byName.get(name);
  }
  for (const k of Object.keys(map)) if (!map[k]) delete map[k];
  return map;
}

// ---- Poser: rest data + pose operations ----------------------------------------------------
const _v1 = new THREE.Vector3(), _v2 = new THREE.Vector3(), _v3 = new THREE.Vector3();
const _q1 = new THREE.Quaternion(), _q2 = new THREE.Quaternion(), _q3 = new THREE.Quaternion();

export class Poser {
  constructor(root, bones, map) {
    this.root = root;
    this.bones = bones;
    this.map = map;
    root.updateMatrixWorld(true);
    this.rest = new Map();
    for (const b of bones) {
      this.rest.set(b, {
        q: b.quaternion.clone(), p: b.position.clone(), s: b.scale.clone(),
        wq: b.getWorldQuaternion(new THREE.Quaternion()), wp: b.getWorldPosition(new THREE.Vector3()),
      });
    }
    this.computeFrame();
    this.computeFingerAxes();
  }

  wp(b, out = new THREE.Vector3()) { return b.getWorldPosition(out); }
  restWP(slot) { const b = this.map[slot]; return b ? this.rest.get(b).wp : null; }

  computeFrame() {
    const r = s => this.restWP(s);
    const up = new THREE.Vector3(0, 1, 0);
    if (r('head') && r('hips')) up.subVectors(r('head'), r('hips')).normalize();
    const left = new THREE.Vector3(1, 0, 0);
    const pairs = [['upperArmL', 'upperArmR'], ['upperLegL', 'upperLegR'], ['handL', 'handR'], ['shoulderL', 'shoulderR']];
    for (const [a, b] of pairs) if (r(a) && r(b)) { left.subVectors(r(a), r(b)); break; }
    left.addScaledVector(up, -left.dot(up)).normalize();
    const fwd = new THREE.Vector3().crossVectors(left, up).normalize();
    this.basis = new THREE.Matrix4().makeBasis(left, up, fwd);
    this.qC = new THREE.Quaternion().setFromRotationMatrix(this.basis);
    this.qCi = this.qC.clone().invert();
    this.up = up; this.left = left; this.fwd = fwd;

    const box = new THREE.Box3();
    for (const b of this.bones) box.expandByPoint(this.rest.get(b).wp);
    this.height = Math.max(1e-3, box.getSize(_v1).dot(up) || box.getSize(_v1).y);
    const leg = (r('upperLegL') && r('footL')) ? r('upperLegL').distanceTo(r('footL')) : this.height * 0.45;
    this.legLen = leg || this.height * 0.45;
  }

  /** char-frame vector -> world */
  toWorldDir(v, out = new THREE.Vector3()) { return out.set(v[0], v[1], v[2]).normalize().applyQuaternion(this.qC); }
  /** char-frame euler (degrees, order YXZ) -> world-space rotation */
  charRot(e, out = new THREE.Quaternion()) {
    const d = THREE.MathUtils.DEG2RAD;
    out.setFromEuler(new THREE.Euler(e[0] * d, e[1] * d, e[2] * d, 'YXZ'));
    return out.premultiply(this.qC).multiply(this.qCi);
  }
  worldRotToChar(q) {
    const c = this.qCi.clone().multiply(q).multiply(this.qC);
    const e = new THREE.Euler().setFromQuaternion(c, 'YXZ');
    const r = THREE.MathUtils.RAD2DEG;
    return [e.x * r, e.y * r, e.z * r];
  }

  /** Total world rotation a bone has gained since rest (includes its parents). */
  delta(b, out = new THREE.Quaternion()) {
    if (!b || !b.isBone || !this.rest.has(b)) return out.identity();
    b.getWorldQuaternion(out);
    return out.multiply(_q3.copy(this.rest.get(b).wq).invert());
  }
  /** The bone's own rotation, expressed in world axes carried by its parent. */
  ownDelta(b) {
    const dp = this.delta(b.parent, new THREE.Quaternion());
    return dp.invert().multiply(this.delta(b, new THREE.Quaternion()));
  }
  setOwnDelta(b, D) {
    const dp = this.delta(b.parent, new THREE.Quaternion());
    const w = dp.multiply(D).multiply(this.rest.get(b).wq);
    this.setWorldQuat(b, w);
  }
  setWorldQuat(b, w) {
    const pw = b.parent.getWorldQuaternion(new THREE.Quaternion());
    b.quaternion.copy(pw.invert().multiply(w));
    b.updateMatrixWorld(true);
  }
  /** Rotate bone `b` so the point `from` (a descendant position) moves toward world point `to`. */
  aim(b, from, to) {
    const o = this.wp(b, _v3);
    const a = _v1.subVectors(from, o), c = _v2.subVectors(to, o);
    if (a.lengthSq() < 1e-12 || c.lengthSq() < 1e-12) return;
    const R = _q1.setFromUnitVectors(a.normalize(), c.normalize());
    const w = b.getWorldQuaternion(_q2).premultiply(R);
    this.setWorldQuat(b, w.clone());
  }
  aimDir(b, childPos, dirWorld) {
    const o = this.wp(b, new THREE.Vector3());
    this.aim(b, childPos, o.clone().add(dirWorld));
  }

  resetBone(b) { const r = this.rest.get(b); b.quaternion.copy(r.q); b.position.copy(r.p); b.updateMatrixWorld(true); }
  resetAll() { for (const b of this.bones) { const r = this.rest.get(b); b.quaternion.copy(r.q); b.position.copy(r.p); } this.root.updateMatrixWorld(true); }

  // --- fingers -------------------------------------------------------------------------------
  computeFingerAxes() {
    this.fingerAxes = new Map();
    for (const s of ['L', 'R']) {
      const m = k => this.map[k + s];
      const base = m('middle1') || m('index1') || m('ring1');
      const hand = m('hand');
      if (!hand || !base) continue;
      const fdir = new THREE.Vector3().subVectors(this.rest.get(base).wp, this.rest.get(hand).wp).normalize();
      let across;
      if (m('index1') && m('little1')) across = new THREE.Vector3().subVectors(this.rest.get(m('little1')).wp, this.rest.get(m('index1')).wp);
      else if (m('index1') && m('ring1')) across = new THREE.Vector3().subVectors(this.rest.get(m('ring1')).wp, this.rest.get(m('index1')).wp);
      else across = this.fwd.clone().negate();
      across.addScaledVector(fdir, -across.dot(fdir)).normalize();
      const palm = s === 'L' ? new THREE.Vector3().crossVectors(across, fdir) : new THREE.Vector3().crossVectors(fdir, across);
      palm.normalize();
      for (const f of FINGERS) for (let i = 1; i <= 3; i++) {
        const b = m(f + i); if (!b) continue;
        const next = m(f + (i + 1)) || b.children.find(c => c.isBone);
        let dir = next ? new THREE.Vector3().subVectors(this.rest.get(next)?.wp || this.wp(next), this.rest.get(b).wp) : fdir.clone();
        if (dir.lengthSq() < 1e-10) dir = fdir.clone();
        dir.normalize();
        let n = palm.clone();
        if (f === 'thumb') n = palm.clone().addScaledVector(across, 0.9).normalize(); // thumb folds across the palm
        const curl = new THREE.Vector3().crossVectors(dir, n).normalize();
        this.fingerAxes.set(b, { curl, spread: palm.clone(), side: s });
      }
    }
  }
  /** fingers: {thumb, index, middle, ring, little: curl 0..1, spread: -1..1} */
  setFingers(side, f) {
    const maxCurl = { thumb: [25, 30, 40], other: [70, 95, 70] };
    const spreadDeg = { thumb: 0, index: 10, middle: 0, ring: -8, little: -16 };
    for (const name of FINGERS) for (let i = 1; i <= 3; i++) {
      const b = this.map[name + i + side]; if (!b) continue;
      const ax = this.fingerAxes.get(b); if (!ax) continue;
      const c = f[name] ?? 0;
      const ang = c * (name === 'thumb' ? maxCurl.thumb : maxCurl.other)[i - 1] * THREE.MathUtils.DEG2RAD;
      const D = new THREE.Quaternion().setFromAxisAngle(ax.curl, ang);
      if (i === 1 && f.spread) {
        const sgn = side === 'L' ? 1 : -1;
        D.premultiply(new THREE.Quaternion().setFromAxisAngle(ax.spread, sgn * (f.spread || 0) * spreadDeg[name] * THREE.MathUtils.DEG2RAD));
      }
      this.setOwnDelta(b, D);
    }
  }

  // --- two-bone IK -------------------------------------------------------------------------------
  solveIK(side, limb, target) {
    const [u, l, e] = limb === 'arm' ? ['upperArm', 'lowerArm', 'hand'] : ['upperLeg', 'lowerLeg', 'foot'];
    const U = this.map[u + side], L = this.map[l + side], E = this.map[e + side];
    if (!U || !L || !E) return;
    const endW = E.getWorldQuaternion(new THREE.Quaternion());
    const A = this.wp(U, new THREE.Vector3()), B = this.wp(L, new THREE.Vector3()), C = this.wp(E, new THREE.Vector3());
    const a = A.distanceTo(B), b = B.distanceTo(C);
    const d = new THREE.Vector3().subVectors(target, A);
    const dist = THREE.MathUtils.clamp(d.length(), 1e-4, (a + b) * 0.9995);
    const n = d.normalize();
    let pole = new THREE.Vector3().subVectors(B, A);
    pole.addScaledVector(n, -pole.dot(n));
    if (pole.lengthSq() < 1e-8 * a * a) {
      pole = limb === 'arm' ? this.fwd.clone().negate().addScaledVector(this.up, -0.5) : this.fwd.clone();
      pole.addScaledVector(n, -pole.dot(n));
    }
    pole.normalize();
    const x = (a * a - b * b + dist * dist) / (2 * dist);
    const h = Math.sqrt(Math.max(0, a * a - x * x));
    const Bd = A.clone().addScaledVector(n, x).addScaledVector(pole, h);
    const Cd = A.clone().addScaledVector(n, dist);
    this.aim(U, B, Bd);
    this.aim(L, this.wp(E, new THREE.Vector3()), Cd);
    this.setWorldQuat(E, endW);
  }

  // --- snapshots (what keyframes and saved poses store) ----------------------------------------
  snapshot() {
    const bones = {};
    for (const b of this.bones) {
      const r = this.rest.get(b);
      if (b.quaternion.angleTo(r.q) > 1e-5) bones[b.name] = b.quaternion.toArray().map(v => +v.toFixed(6));
    }
    const hips = this.map.hips;
    const pos = hips && hips.position.distanceTo(this.rest.get(hips).p) > 1e-6 ? hips.position.toArray().map(v => +v.toFixed(6)) : null;
    return { bones, hips: pos };
  }
  restore(snap) {
    for (const b of this.bones) {
      const r = this.rest.get(b);
      const q = snap.bones?.[b.name];
      if (q) b.quaternion.fromArray(q); else b.quaternion.copy(r.q);
    }
    if (this.map.hips) {
      const r = this.rest.get(this.map.hips);
      if (snap.hips) this.map.hips.position.fromArray(snap.hips); else this.map.hips.position.copy(r.p);
    }
    this.root.updateMatrixWorld(true);
  }

  /** Mirror a snapshot left <-> right (bones paired by name). */
  mirrorSnapshot(snap) {
    const byName = new Map(this.bones.map(b => [b.name, b]));
    const out = { bones: {}, hips: null };
    const cur = this.snapshot(); this.restore(snap);
    // Gather each bone's own delta in char frame, mirror it, and write it to the paired bone.
    const deltas = new Map();
    for (const b of this.bones) deltas.set(b.name, this.ownDelta(b));
    let hipOffset = null;
    if (this.map.hips) {
      const h = this.map.hips;
      const w = this.wp(h, new THREE.Vector3()).sub(this.rest.get(h).wp).applyQuaternion(this.qCi);
      hipOffset = w;
    }
    this.resetAll();
    for (const b of this.bones) {
      const src = byName.get(mirrorName(b.name)) || b;
      const D = deltas.get(src.name);
      const c = this.qCi.clone().multiply(D).multiply(this.qC);
      c.set(c.x, -c.y, -c.z, c.w);
      this.setOwnDelta(b, this.qC.clone().multiply(c).multiply(this.qCi));
    }
    if (hipOffset) this.moveHipsChar([-hipOffset.x, hipOffset.y, hipOffset.z], true);
    const res = this.snapshot();
    this.restore(cur);
    Object.assign(out, res);
    return out;
  }

  /** Move hips by an offset in char frame (absolute from rest when `abs`, world units). */
  moveHipsChar(off, abs = true) {
    const h = this.map.hips; if (!h) return;
    const r = this.rest.get(h);
    const targetW = (abs ? r.wp.clone() : this.wp(h, new THREE.Vector3())).add(new THREE.Vector3(...off).applyQuaternion(this.qC));
    const local = h.parent.worldToLocal(targetW.clone());
    h.position.copy(local);
    h.updateMatrixWorld(true);
  }

  /** Lowest point of the feet relative to rest, along up. */
  footDrop() {
    const pts = ['toesL', 'toesR', 'footL', 'footR'].map(s => this.map[s]).filter(Boolean);
    if (!pts.length) return 0;
    const restMin = Math.min(...pts.map(b => this.rest.get(b).wp.dot(this.up)));
    const nowMin = Math.min(...pts.map(b => this.wp(b, _v1).dot(this.up)));
    return nowMin - restMin;
  }
}

/** Name of the bone on the other side: "Bip001 L Hand" <-> "Bip001 R Hand", 左腕 <-> 右腕. */
export function mirrorName(name) {
  for (const [a, b] of [['Left', 'Right'], ['left', 'right'], ['LEFT', 'RIGHT'], ['左', '右']]) {
    if (name.includes(a)) return name.split(a).join(b);
    if (name.includes(b)) return name.split(b).join(a);
  }
  const re = /(^|[^A-Za-z])([LRlr])(?=[^A-Za-z]|$)/;
  const m = name.match(re);
  if (m) return name.replace(re, (_, p) => p + { L: 'R', R: 'L', l: 'r', r: 'l' }[m[2]]);
  return name;
}

/** Collect skinned bones of a loaded scene, parents first, without duplicates. */
export function collectBones(root) {
  const set = new Set();
  root.traverse(o => { if (o.isSkinnedMesh) o.skeleton.bones.forEach(b => set.add(b)); });
  root.traverse(o => { if (o.isBone) set.add(o); });
  const out = [];
  root.traverse(o => { if (set.has(o)) out.push(o); });
  return out;
}

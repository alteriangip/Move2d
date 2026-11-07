// Keyframe timeline: each key is a full pose snapshot (bone rotations, hips position, face).
import * as THREE from 'three';

const ease = t => t * t * (3 - 2 * t);

export class Timeline {
  constructor() { this.keys = []; this.duration = 2; this.loop = true; this.smooth = true; }

  toJSON() { return { duration: this.duration, loop: this.loop, smooth: this.smooth, keys: this.keys }; }
  load(o) {
    this.keys = (o.keys || []).map(k => ({ t: k.t, pose: k.pose, face: k.face || {} })).sort((a, b) => a.t - b.t);
    this.duration = o.duration || Math.max(1, this.keys.at(-1)?.t || 1);
    this.loop = o.loop ?? true; this.smooth = o.smooth ?? true;
  }

  keyAt(t, eps = 0.02) { return this.keys.find(k => Math.abs(k.t - t) < eps); }
  setKey(t, pose, face) {
    t = Math.round(t * 100) / 100;
    const k = this.keyAt(t);
    if (k) { k.pose = pose; k.face = face; }
    else { this.keys.push({ t, pose, face }); this.keys.sort((a, b) => a.t - b.t); }
    if (t > this.duration) this.duration = t;
  }
  removeKey(t) { const k = this.keyAt(t); if (k) this.keys.splice(this.keys.indexOf(k), 1); return !!k; }
  moveKey(from, to) { const k = this.keyAt(from); if (!k) return; this.keys.splice(this.keys.indexOf(k), 1); this.setKey(to, k.pose, k.face); }
  next(t) { return this.keys.find(k => k.t > t + 0.011); }
  prev(t) { return [...this.keys].reverse().find(k => k.t < t - 0.011); }

  /** Write the interpolated pose at time t into the poser and face. */
  evaluate(t, poser, face) {
    if (!this.keys.length) return;
    let a = this.keys[0], b = a;
    if (t <= a.t) b = a;
    else if (t >= this.keys.at(-1).t) a = b = this.keys.at(-1);
    else for (let i = 0; i < this.keys.length - 1; i++) if (t >= this.keys[i].t && t <= this.keys[i + 1].t) { a = this.keys[i]; b = this.keys[i + 1]; break; }
    let u = a === b ? 0 : (t - a.t) / (b.t - a.t);
    if (this.smooth) u = ease(u);
    const qa = new THREE.Quaternion(), qb = new THREE.Quaternion();
    for (const bone of poser.bones) {
      const r = poser.rest.get(bone).q;
      const A = a.pose.bones[bone.name], B = b.pose.bones[bone.name];
      if (!A && !B) { bone.quaternion.copy(r); continue; }
      A ? qa.fromArray(A) : qa.copy(r);
      B ? qb.fromArray(B) : qb.copy(r);
      bone.quaternion.slerpQuaternions(qa, qb, u);
    }
    const h = poser.map.hips;
    if (h) {
      const r = poser.rest.get(h).p;
      const pa = a.pose.hips ? new THREE.Vector3().fromArray(a.pose.hips) : r;
      const pb = b.pose.hips ? new THREE.Vector3().fromArray(b.pose.hips) : r;
      h.position.lerpVectors(pa, pb, u);
    }
    poser.root.updateMatrixWorld(true);
    if (face) {
      const names = new Set([...Object.keys(a.face), ...Object.keys(b.face), ...Object.keys(face.snapshot())]);
      for (const n of names) face.set(n, (a.face[n] || 0) * (1 - u) + (b.face[n] || 0) * u);
    }
  }

  /** Build a three.js AnimationClip (bones addressed by uuid so any bone name exports safely). */
  toClip(poser, face, name = 'Move2D', fps = 30) {
    const tracks = [];
    const times = [];
    const n = Math.max(2, Math.round(this.duration * fps) + 1);
    for (let i = 0; i < n; i++) times.push(Math.min(this.duration, i / fps));
    const rot = new Map(poser.bones.map(b => [b, []]));
    const hips = [];
    const morphs = new Map();
    for (const t of times) {
      this.evaluate(t, poser, face);
      for (const b of poser.bones) rot.get(b).push(...b.quaternion.toArray());
      if (poser.map.hips) hips.push(...poser.map.hips.position.toArray());
      if (face) for (const m of face.meshes) {
        if (!morphs.has(m)) morphs.set(m, []);
        morphs.get(m).push(...m.morphTargetInfluences);
      }
    }
    for (const b of poser.bones) {
      const v = rot.get(b);
      const moving = v.some((x, i) => Math.abs(x - v[i % 4]) > 1e-5);
      if (moving || this.keys.some(k => k.pose.bones[b.name])) tracks.push(new THREE.QuaternionKeyframeTrack(b.uuid + '.quaternion', times, v));
    }
    if (poser.map.hips) tracks.push(new THREE.VectorKeyframeTrack(poser.map.hips.uuid + '.position', times, hips));
    for (const [m, v] of morphs) if (v.some(x => x > 1e-4)) tracks.push(new THREE.NumberKeyframeTrack(m.uuid + '.morphTargetInfluences', times, v));
    return new THREE.AnimationClip(name, this.duration, tracks);
  }
}

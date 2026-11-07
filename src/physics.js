// Spring-bone "jiggle" physics for secondary bones (hair, tail, clothes, chest), in the style of VRM spring bones.
// The pose system owns each bone's authored rotation; physics adds sway on top and never writes into keyframes.
import * as THREE from 'three';

export const GROUPS = {
  hair: { label: 'Hair', re: /hair|bang|ponytail|twintail|braid|ahoge|髪/i, stiffness: 1.1, drag: 0.42, gravity: 0.3 },
  tail: { label: 'Tail', re: /tail|尻尾|しっぽ/i, stiffness: 0.6, drag: 0.3, gravity: 0.15 },
  cloth: { label: 'Clothes', re: /skirt|jac(ket)?(?![a-z])|coat|cape|cloak|cloth|tie|ribbon|scarf|dress|hood|pendent|pendant|string|strap|sleeve|frill|tassel|スカート|リボン/i, stiffness: 1.4, drag: 0.45, gravity: 0.35 },
  chest: { label: 'Chest', re: /(^|[^a-z])(chest|breast|bust|boob)(_?\d)?([^a-z]|$)|胸/i, not: /cj|collar|jac|spine/i, stiffness: 7, drag: 0.3, gravity: 0, leafLen: 0.06 },
};
const SKIP = /twist|fix|shake|roll|_end$|\.end$|nub|ik(_|$)|pole|^mch|^org|^wgt/i;

const _v = new THREE.Vector3(), _w = new THREE.Vector3(), _q = new THREE.Quaternion(), _q2 = new THREE.Quaternion();

export class SpringPhysics {
  constructor(poser) {
    this.poser = poser;
    this.enabled = true;
    this.groups = { hair: true, tail: true, cloth: true, chest: true };
    this.bounce = 1;   // 0 stiff .. 2 floppy
    this.gravityScale = 1;
    this.paused = new Set();
    const mapped = new Set(Object.values(poser.map));
    const H = poser.height;
    this.joints = [];
    for (const bone of poser.bones) {
      if (mapped.has(bone) || SKIP.test(bone.name) || !bone.parent?.isBone) continue;
      const group = Object.entries(GROUPS).find(([, g]) => g.re.test(bone.name) && !(g.not && g.not.test(bone.name)));
      if (!group) continue;
      const [gid, g] = group;
      // tail point in bone-local space: its child bone, else along the bone's own axis
      const child = bone.children.find(c => c.isBone);
      let axis;
      if (child && child.position.lengthSq() > 1e-10) axis = child.position.clone();
      else if (bone.userData.boneLength) axis = new THREE.Vector3(0, bone.userData.boneLength, 0);
      else axis = new THREE.Vector3(0, (g.leafLen || 0.04) * H / bone.getWorldScale(_v).x, 0);
      this.joints.push({ bone, group: gid, axis: axis.clone().normalize(), localLen: axis.length(), authored: bone.quaternion.clone(), cur: new THREE.Vector3(), prev: new THREE.Vector3(), radius: 0.008 * H });
    }
    this.counts = Object.fromEntries(Object.keys(GROUPS).map(k => [k, this.joints.filter(j => j.group === k).length]));
    this.buildColliders(H);
    this.reset();
  }

  buildColliders(H) {
    const m = this.poser.map, up = this.poser.up;
    this.colliders = [];
    const add = (bone, r, toward, t = 0, lift = 0) => { if (bone) this.colliders.push({ bone, toward, t, r: r * H, lift: lift * H }); };
    add(m.head, 0.075, null, 0, 0.055);
    add(m.neck, 0.035);
    add(m.upperChest || m.chest, 0.085);
    add(m.chest || m.spine, 0.08);
    add(m.spine, 0.08);
    add(m.hips, 0.09);
    for (const s of ['L', 'R']) {
      for (const t of [0.25, 0.6]) add(m['upperLeg' + s], 0.06, m['lowerLeg' + s], t);
      add(m['lowerLeg' + s], 0.045, m['foot' + s], 0.4);
      add(m['upperArm' + s], 0.035, m['lowerArm' + s], 0.5);
      add(m['lowerArm' + s], 0.03, m['hand' + s], 0.5);
    }
    this.up = up;
  }

  colliderPos(c, out) {
    c.bone.getWorldPosition(out);
    if (c.toward) out.lerp(c.toward.getWorldPosition(_w), c.t);
    if (c.lift) out.addScaledVector(this.up, c.lift);
    return out;
  }

  /** Put every spring at rest under the current pose (no swing). */
  reset() {
    this.poser.root.updateMatrixWorld(true);
    for (const j of this.joints) {
      j.bone.quaternion.copy(j.authored);
      j.bone.updateMatrixWorld(true);
      j.cur.copy(j.axis).multiplyScalar(j.localLen).applyMatrix4(j.bone.matrixWorld);
      j.prev.copy(j.cur);
    }
  }

  /** Read the pose system's rotations as the springs' rest (call after anything that sets all bones). */
  sync() { for (const j of this.joints) j.authored.copy(j.bone.quaternion); }

  /** Run fn with the authored (physics-free) rotations in place, e.g. to take a snapshot. */
  withAuthored(fn) {
    const saved = this.joints.map(j => j.bone.quaternion.clone());
    for (const j of this.joints) j.bone.quaternion.copy(j.authored);
    this.poser.root.updateMatrixWorld(true);
    try { return fn(); } finally {
      this.joints.forEach((j, i) => j.bone.quaternion.copy(saved[i]));
      this.poser.root.updateMatrixWorld(true);
    }
  }

  /** The user rotated a spring bone by hand: make that its rest. */
  setAuthored(bone) { const j = this.joints.find(x => x.bone === bone); if (j) { j.authored.copy(bone.quaternion); } }
  has(bone) { return this.joints.some(j => j.bone === bone); }

  update(dt) {
    if (!this.joints.length) return;
    const on = this.enabled;
    for (const j of this.joints) j.bone.quaternion.copy(j.authored);
    this.poser.root.updateMatrixWorld(true);
    if (!on) return;
    const steps = Math.min(4, Math.max(1, Math.round(dt * 60)));
    const h = Math.min(dt, 1 / 15) / steps;
    const gravityDir = this.up.clone().negate();
    const cpos = this.colliders.map(() => new THREE.Vector3());
    for (let s = 0; s < steps; s++) {
      this.colliders.forEach((c, i) => this.colliderPos(c, cpos[i]));
      for (const j of this.joints) {
        if (!this.groups[j.group] || this.paused.has(j.bone)) { this.restJoint(j); continue; }
        const g = GROUPS[j.group];
        const bone = j.bone, parent = bone.parent;
        const worldPos = bone.getWorldPosition(_v).clone();
        const scale = bone.getWorldScale(_w).x;
        const len = j.localLen * scale;
        // rest direction under the authored rotation
        const restRot = parent.getWorldQuaternion(_q).multiply(j.authored);
        const restDir = j.axis.clone().applyQuaternion(restRot);
        const floppy = Math.max(0.05, this.bounce);
        const stiff = g.stiffness / floppy;
        const drag = Math.min(0.95, g.drag * (floppy < 1 ? 1 / floppy : 1 / Math.sqrt(floppy)));
        const next = j.cur.clone()
          .addScaledVector(_w.subVectors(j.cur, j.prev), 1 - drag)
          .addScaledVector(restDir, stiff * h)
          .addScaledVector(gravityDir, g.gravity * this.gravityScale * h);
        next.sub(worldPos).setLength(len).add(worldPos);
        // collide with body spheres
        for (let i = 0; i < this.colliders.length; i++) {
          const c = this.colliders[i], d = _w.subVectors(next, cpos[i]), r = c.r + j.radius, l = d.length();
          if (l < r && l > 1e-6) { next.copy(cpos[i]).addScaledVector(d, r / l); next.sub(worldPos).setLength(len).add(worldPos); }
        }
        j.prev.copy(j.cur); j.cur.copy(next);
        // rotate the bone so its tail points at the simulated point
        const toLocal = restRot.clone().invert();
        const dirLocal = _w.subVectors(next, worldPos).applyQuaternion(toLocal).normalize();
        bone.quaternion.copy(j.authored).multiply(_q2.setFromUnitVectors(j.axis, dirLocal));
        bone.updateMatrixWorld(true);
      }
    }
  }

  restJoint(j) {
    j.bone.updateMatrixWorld(true);
    j.cur.copy(j.axis).multiplyScalar(j.localLen).applyMatrix4(j.bone.matrixWorld);
    j.prev.copy(j.cur);
  }
}

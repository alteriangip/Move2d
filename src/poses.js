// Preset poses, authored in the character frame (see rig.js):
//   dir:  limb bone directions. x = character's left, y = up, z = forward. Relative to the torso
//         (arms) or hips (legs), so they follow when the body turns.
//   rot:  [x, y, z] degrees on that bone. x+ bends forward, y+ turns to her left, z+ tilts to her right.
//   abs:  world-space rotation from rest, for feet that should stay flat or point.
//   hips: offset in leg lengths. air: skip planting the feet on the floor.
//   fingers: per hand, curl 0..1 per finger and spread -1..1. morphs: face shape keys by meaning.
import * as THREE from 'three';

const M = ([x, y, z]) => [-x, y, z];          // mirror a direction left/right
const ME = ([x, y, z]) => [x, -y, -z];        // mirror an euler left/right

const HAND = {
  relaxed: { thumb: 0.25, index: 0.2, middle: 0.28, ring: 0.34, little: 0.4, spread: 0.1 },
  open: { thumb: 0, index: 0, middle: 0, ring: 0, little: 0, spread: 0.6 },
  fist: { thumb: 0.9, index: 1, middle: 1, ring: 1, little: 1 },
  point: { thumb: 0.8, index: 0, middle: 1, ring: 1, little: 1 },
  peace: { thumb: 0.9, index: 0, middle: 0, ring: 1, little: 1, spread: 0.9 },
  claw: { thumb: 0.4, index: 0.55, middle: 0.55, ring: 0.6, little: 0.6, spread: 0.7 },
  soft: { thumb: 0.15, index: 0.1, middle: 0.15, ring: 0.2, little: 0.25, spread: 0.3 },
  grip: { thumb: 0.6, index: 0.7, middle: 0.75, ring: 0.8, little: 0.85 },
};

const ARMS_DOWN = { upperArmL: [0.22, -1, 0], lowerArmL: [0.12, -1, 0.15], upperArmR: [-0.22, -1, 0], lowerArmR: [-0.12, -1, 0.15] };
const HIP_HAND_L = { upperArmL: [0.72, -0.62, -0.25], lowerArmL: [-0.55, -0.75, 0.22] };
const HIP_HAND_R = { upperArmR: M(HIP_HAND_L.upperArmL), lowerArmR: M(HIP_HAND_L.lowerArmL) };
const STAND = { upperLegL: [0.04, -1, 0], lowerLegL: [0, -1, -0.02], upperLegR: [-0.04, -1, 0], lowerLegR: [0, -1, -0.02] };
const CONTRA = { upperLegL: [0.07, -1, -0.02], lowerLegL: [0, -1, 0], upperLegR: [0.03, -0.96, 0.2], lowerLegR: [-0.06, -1, -0.12] };

export const POSES = [
  { id: 'rest', name: 'Rest', group: 'Basics', reset: true },
  { id: 'tpose', name: 'T-pose', group: 'Basics', dir: { upperArmL: [1, 0, 0], lowerArmL: [1, 0, 0], upperArmR: [-1, 0, 0], lowerArmR: [-1, 0, 0], ...STAND }, fingers: { L: HAND.open, R: HAND.open } },
  { id: 'stand', name: 'Relaxed stand', group: 'Basics',
    hips: [0.02, 0, 0], rot: { hips: [0, 0, 3], spine: [2, 0, -2], head: [2, 0, 2] },
    dir: { ...ARMS_DOWN, upperLegL: [0.03, -1, 0], lowerLegL: [0, -1, 0], upperLegR: [-0.07, -1, 0.06], lowerLegR: [0, -1, -0.06] },
    fingers: { L: HAND.relaxed, R: HAND.relaxed } },

  // Attitude: sly and playful. Combat: quick, acrobatic, kick-heavy.
  { id: 'sly', name: 'Hand on hip', group: 'Attitude',
    hips: [0.04, 0, 0], rot: { hips: [0, -8, 6], spine: [0, 4, -3], chest: [-3, 6, -4], neck: [0, -4, 0], head: [-4, -10, 7] },
    dir: { ...HIP_HAND_L, upperArmR: [-0.25, -1, 0.05], lowerArmR: [-0.15, -1, 0.2], ...CONTRA },
    fingers: { L: HAND.soft, R: HAND.relaxed }, morphs: { smile: 0.5 } },
  { id: 'shh', name: 'Shh, a secret', group: 'Attitude',
    hips: [0.03, 0, 0], rot: { hips: [0, -6, 5], chest: [3, -6, -2], head: [6, -8, -6] },
    dir: { ...HIP_HAND_L, upperArmR: [-0.22, -0.9, 0.42], lowerArmR: [0.28, 0.86, 0.4], ...CONTRA },
    fingers: { L: HAND.soft, R: HAND.point }, morphs: { wink: 1, smile: 0.4 } },
  { id: 'peace', name: 'Peace sign wink', group: 'Attitude',
    rot: { hips: [0, 0, 5], chest: [0, -8, -3], head: [0, -6, -12] },
    dir: { ...HIP_HAND_L, upperArmR: [-0.62, -0.5, 0.35], lowerArmR: [0.32, 0.92, 0.15], ...STAND },
    fingers: { L: HAND.soft, R: HAND.peace }, morphs: { wink: 1, smile: 0.8 } },
  { id: 'glance', name: 'Over-the-shoulder look', group: 'Attitude',
    rot: { hips: [0, 150, 0], spine: [0, -12, 0], chest: [-4, -22, 0], neck: [0, -28, 0], head: [-6, -35, 8] },
    dir: { ...HIP_HAND_L, upperArmR: [-0.2, -1, 0.05], lowerArmR: [-0.1, -1, 0.2], ...CONTRA },
    fingers: { L: HAND.soft, R: HAND.relaxed }, morphs: { smile: 0.4 } },
  { id: 'crossed', name: 'Arms crossed', group: 'Attitude',
    hips: [-0.03, 0, 0], rot: { hips: [0, 6, -4], chest: [-4, 0, 2], head: [-8, 15, 0] },
    dir: { upperArmL: [0.36, -0.85, 0.38], lowerArmL: [-0.95, 0.12, 0.3], upperArmR: [-0.36, -0.85, 0.42], lowerArmR: [0.95, 0.2, 0.22],
      upperLegL: [0.03, -0.96, 0.18], lowerLegL: [0.06, -1, -0.1], upperLegR: [-0.07, -1, -0.02], lowerLegR: [0, -1, 0] },
    fingers: { L: HAND.grip, R: HAND.grip } },
  { id: 'think', name: 'Thinking', group: 'Attitude',
    rot: { chest: [4, -5, 0], head: [10, -12, 9] },
    dir: { upperArmR: [-0.3, -0.9, 0.32], lowerArmR: [0.22, 0.9, 0.38], upperArmL: [0.36, -0.85, 0.38], lowerArmL: [-0.95, 0.12, 0.3], ...CONTRA },
    fingers: { L: HAND.relaxed, R: HAND.grip } },
  { id: 'behindhead', name: 'Hands behind head', group: 'Attitude',
    hips: [0.03, 0, 0], rot: { hips: [0, 0, 6], chest: [-8, 0, -3], head: [-5, 8, 4] },
    dir: { upperArmL: [0.85, 0.5, -0.12], lowerArmL: [-0.62, 0.5, -0.6], upperArmR: [-0.85, 0.5, -0.12], lowerArmR: [0.62, 0.5, -0.6], ...CONTRA },
    fingers: { L: HAND.soft, R: HAND.soft }, morphs: { smile: 0.6 } },
  { id: 'kiss', name: 'Blow a kiss', group: 'Attitude',
    rot: { hips: [0, -5, 4], chest: [4, -8, 0], head: [4, -6, -8] },
    dir: { upperArmR: [-0.3, -0.42, 0.85], lowerArmR: [0.08, 0.4, 0.9], upperArmL: [0.2, -0.92, -0.35], lowerArmL: [-0.62, -0.42, -0.65], ...CONTRA },
    fingers: { L: HAND.relaxed, R: HAND.open }, morphs: { wink: 1, smile: 0.7 } },
  { id: 'wave', name: 'Wave', group: 'Attitude',
    rot: { chest: [0, -6, 0], head: [0, -5, -6] },
    dir: { upperArmR: [-0.82, 0.45, 0.2], lowerArmR: [-0.1, 1, 0.12], upperArmL: [0.22, -1, 0], lowerArmL: [0.12, -1, 0.15], ...STAND },
    fingers: { L: HAND.relaxed, R: HAND.open }, morphs: { smile: 0.9 } },

  { id: 'ready', name: 'Agent ready stance', group: 'Combat',
    hips: [0, -0.1, 0], rot: { hips: [0, -32, 0], spine: [10, 10, 0], chest: [6, 10, 0], neck: [0, 5, 0], head: [-8, 12, 0] },
    dir: { upperArmL: [0.3, -0.42, 0.8], lowerArmL: [-0.12, 0.7, 0.62], upperArmR: [-0.5, -0.62, 0.42], lowerArmR: [0.62, 0.32, 0.6],
      upperLegL: [0.32, -0.82, 0.36], lowerLegL: [0.1, -1, -0.12], upperLegR: [-0.32, -0.82, -0.3], lowerLegR: [-0.08, -1, -0.25] },
    fingers: { L: HAND.fist, R: HAND.fist }, morphs: { smile: 0.25 } },
  { id: 'kick', name: 'High kick', group: 'Combat',
    rot: { hips: [-10, -10, 0], spine: [-6, 0, 0], chest: [6, 0, 0], head: [10, 8, 0] },
    dir: { upperLegL: [0.05, 0.5, 1], lowerLegL: [0, 0.62, 1], upperLegR: [-0.06, -1, -0.1], lowerLegR: [0, -1, 0],
      upperArmL: [0.9, 0.1, -0.4], lowerArmL: [0.9, 0.2, -0.3], upperArmR: [-0.85, 0.3, 0.25], lowerArmR: [-0.75, 0.5, 0.35] },
    abs: { footL: [-55, 0, 0] }, fingers: { L: HAND.open, R: HAND.fist } },
  { id: 'spin', name: 'Spinning back kick', group: 'Combat',
    rot: { hips: [12, 45, 0], spine: [8, 18, 0], chest: [4, 15, 0], head: [-12, -40, 0] },
    dir: { upperLegR: [-0.22, 0.38, -0.9], lowerLegR: [-0.2, 0.45, -0.86], upperLegL: [0.06, -0.96, 0.2], lowerLegL: [0, -1, -0.12],
      upperArmL: [0.82, 0, 0.6], lowerArmL: [0.6, 0.1, 0.8], upperArmR: [-0.9, -0.2, -0.32], lowerArmR: [-0.8, 0, -0.6] },
    abs: { footR: [55, 45, 0] }, fingers: { L: HAND.fist, R: HAND.open } },
  { id: 'prowl', name: 'Crouch prowl', group: 'Combat',
    hips: [0, -0.42, 0], rot: { spine: [25, 0, 0], chest: [12, 0, 0], neck: [-10, 0, 0], head: [-25, 0, 0] },
    dir: { upperLegL: [0.2, -0.22, 0.95], lowerLegL: [0.05, -1, -0.1], upperLegR: [-0.2, -0.95, -0.1], lowerLegR: [-0.05, -0.15, -1],
      upperArmL: [0.3, -0.85, 0.42], lowerArmL: [0.15, -0.95, 0.3], upperArmR: [-0.2, -0.75, 0.62], lowerArmR: [-0.05, -0.9, 0.42] },
    abs: { footR: [70, 0, 0] }, fingers: { L: HAND.claw, R: HAND.claw }, morphs: { smile: 0.4 } },
  { id: 'jump', name: 'Mid-air flip', group: 'Combat', air: true,
    hips: [0, 0.35, 0], rot: { hips: [-10, 0, 0], spine: [-8, 0, 0], head: [-10, 0, 0] },
    dir: { upperLegL: [0.15, -0.3, 0.95], lowerLegL: [0.05, -0.92, -0.42], upperLegR: [-0.15, -0.9, -0.32], lowerLegR: [-0.05, -0.3, -1],
      upperArmL: [0.5, 0.85, 0.1], lowerArmL: [0.3, 0.95, 0.12], upperArmR: [-0.95, 0.2, 0], lowerArmR: [-0.9, 0.42, 0.1] },
    abs: { footL: [30, 0, 0], footR: [40, 0, 0] }, fingers: { L: HAND.open, R: HAND.open }, morphs: { smile: 0.7 } },

  { id: 'sit', name: 'Sitting on a ledge', group: 'Resting', air: true,
    hips: [0, -0.48, -0.02], rot: { spine: [-4, 0, 0], chest: [6, 0, 0], head: [6, -8, 6] },
    dir: { upperLegL: [0.1, -0.05, 1], lowerLegL: [0.05, -1, 0.1], upperLegR: [-0.04, 0.05, 1], lowerLegR: [-0.02, -0.9, -0.32],
      upperArmL: [0.42, -0.9, -0.15], lowerArmL: [0.15, -1, -0.05], upperArmR: [-0.42, -0.9, -0.15], lowerArmR: [-0.15, -1, -0.05] },
    abs: { footL: [20, 0, 0], footR: [30, 0, 0] }, fingers: { L: HAND.open, R: HAND.open } },
  { id: 'kneel', name: 'Kneeling', group: 'Resting',
    hips: [0, -0.5, 0], rot: { spine: [4, 0, 0], head: [8, 0, 0] },
    dir: { upperLegL: [0.12, -0.95, 0.35], lowerLegL: [0.04, -0.1, -1], upperLegR: [-0.12, -0.95, 0.35], lowerLegR: [-0.04, -0.1, -1],
      upperArmL: [0.18, -0.9, 0.35], lowerArmL: [-0.2, -0.45, 0.85], upperArmR: [-0.18, -0.9, 0.35], lowerArmR: [0.2, -0.45, 0.85] },
    abs: { footL: [80, 0, 0], footR: [80, 0, 0] }, fingers: { L: HAND.soft, R: HAND.soft } },
  { id: 'lean', name: 'Leaning back', group: 'Resting',
    hips: [0, -0.03, -0.05], rot: { hips: [-6, 0, 0], spine: [-8, 0, 0], chest: [-4, 10, 0], head: [8, -14, 6] },
    dir: { upperArmL: [0.3, -0.85, -0.42], lowerArmL: [0.1, -0.7, -0.7], upperArmR: [-0.3, -0.85, -0.42], lowerArmR: [-0.1, -0.7, -0.7],
      upperLegL: [0.04, -1, 0.05], lowerLegL: [0, -1, 0], upperLegR: [0.08, -0.94, 0.3], lowerLegR: [-0.1, -1, -0.05] },
    fingers: { L: HAND.relaxed, R: HAND.relaxed } },
];

const ARM_SLOTS = ['upperArm', 'lowerArm'];
const LEG_SLOTS = ['upperLeg', 'lowerLeg'];
const CHILD = { upperArm: 'lowerArm', lowerArm: 'hand', upperLeg: 'lowerLeg', lowerLeg: 'foot', hand: 'middle1', foot: 'toes' };

/** Apply a preset pose to the poser. `morph(name, value)` sets face shape keys. */
export function applyPose(poser, pose, morph) {
  poser.resetAll();
  if (pose.reset) { morph?.reset(); return; }
  const m = poser.map;
  const D = new THREE.Quaternion();

  if (pose.hips && m.hips) poser.moveHipsChar(pose.hips.map(v => v * poser.legLen), true);

  const torso = ['hips', 'spine', 'chest', 'upperChest', 'neck', 'head'];
  // Spread spine rotation over bones the rig lacks (e.g. no upperChest -> chest takes it).
  const rot = { ...(pose.rot || {}) };
  if (rot.upperChest && !m.upperChest) { rot.chest = add(rot.chest, rot.upperChest); delete rot.upperChest; }
  if (rot.chest && !m.chest) { rot.spine = add(rot.spine, rot.chest); delete rot.chest; }
  if (rot.neck && !m.neck) { rot.head = add(rot.head, rot.neck); delete rot.neck; }
  for (const s of torso) if (rot[s] && m[s]) poser.setOwnDelta(m[s], poser.charRot(rot[s], D));

  for (const side of ['L', 'R']) {
    for (const [group, slots] of [['arm', ARM_SLOTS], ['leg', LEG_SLOTS]]) {
      const first = m[slots[0] + side];
      if (!first) continue;
      if (rot['shoulder' + side] && m['shoulder' + side]) poser.setOwnDelta(m['shoulder' + side], poser.charRot(rot['shoulder' + side], D));
      const frame = poser.delta(first.parent, new THREE.Quaternion());
      for (const s of slots) {
        const v = pose.dir?.[s + side];
        const b = m[s + side], c = m[CHILD[s] + side];
        if (!v || !b || !c) continue;
        const dirW = poser.toWorldDir(v).applyQuaternion(frame);
        poser.aimDir(b, poser.wp(c), dirW);
      }
      void group;
    }
    for (const s of ['hand', 'foot']) {
      const b = m[s + side];
      if (!b) continue;
      if (pose.abs?.[s + side]) poser.setWorldQuat(b, poser.charRot(pose.abs[s + side]).multiply(poser.rest.get(b).wq));
      else if (pose.rot?.[s + side]) poser.setOwnDelta(b, poser.charRot(pose.rot[s + side], D));
      else if (s === 'foot' && pose.dir?.['upperLeg' + side]) {
        // keep the sole flat, turned with the hips
        const yaw = poser.worldRotToChar(poser.delta(m.hips || b.parent, new THREE.Quaternion()))[1];
        poser.setWorldQuat(b, poser.charRot([0, yaw, 0]).multiply(poser.rest.get(b).wq));
      }
    }
    const f = pose.fingers?.[side];
    if (f) poser.setFingers(side, f);
  }

  if (!pose.air && m.hips) {
    const drop = poser.footDrop();
    if (Math.abs(drop) > 1e-5) poser.moveHipsChar([0, -drop, 0], false);
  }
  if (morph) { morph.reset(); for (const [k, v] of Object.entries(pose.morphs || {})) morph.setMeaning(k, v); }
}

const add = (a = [0, 0, 0], b = [0, 0, 0]) => a.map((v, i) => v + b[i]);

/** Mirror a preset definition (swap left and right). */
export function mirrorPose(p) {
  const sw = o => o && Object.fromEntries(Object.entries(o).map(([k, v]) => [k.replace(/L$/, '\0').replace(/R$/, 'L').replace('\0', 'R'), v]));
  const mapv = (o, f) => o && Object.fromEntries(Object.entries(o).map(([k, v]) => [k, f(v)]));
  return { ...p, hips: p.hips && M(p.hips), dir: mapv(sw(p.dir), M), rot: mapv(sw(p.rot), ME), abs: mapv(sw(p.abs), ME), fingers: p.fingers && { L: p.fingers.R, R: p.fingers.L } };
}

// ---- preset animations: sequences of poses (with optional tweaks) ------------------------------
const P = id => POSES.find(p => p.id === id);
const tweak = (id, patch) => {
  const b = P(id);
  const out = { ...b };
  for (const k of ['rot', 'dir', 'abs', 'fingers', 'morphs']) if (patch[k]) out[k] = { ...(b[k] || {}), ...patch[k] };
  if (patch.hips) out.hips = patch.hips;
  return out;
};

const walk = (lead) => {
  const L = lead === 'L';
  const fw = L ? 1 : -1;
  return {
    hips: [0, -0.04, 0], rot: { hips: [0, 6 * fw, 0], chest: [4, -10 * fw, 0], head: [0, 4 * fw, 0] },
    dir: {
      upperLegL: [0.04, -0.92, 0.38 * fw], lowerLegL: [0, -1, L ? 0.12 : -0.45],
      upperLegR: [-0.04, -0.92, -0.38 * fw], lowerLegR: [0, -1, L ? -0.45 : 0.12],
      upperArmL: [0.2, -1, -0.3 * fw], lowerArmL: [0.1, -0.9, -0.1 * fw + 0.25],
      upperArmR: [-0.2, -1, 0.3 * fw], lowerArmR: [-0.1, -0.9, 0.1 * fw + 0.25],
    },
    fingers: { L: HAND.relaxed, R: HAND.relaxed },
  };
};
const pass = (lead) => {
  const L = lead === 'L';
  return {
    hips: [0, 0.01, 0], rot: { chest: [3, 0, 0] },
    dir: {
      upperLegL: L ? [0.04, -1, 0] : [0.04, -0.9, 0.3], lowerLegL: L ? [0, -1, 0] : [0, -0.8, -0.6],
      upperLegR: L ? [-0.04, -0.9, 0.3] : [-0.04, -1, 0], lowerLegR: L ? [0, -0.8, -0.6] : [0, -1, 0],
      ...ARMS_DOWN,
    },
    fingers: { L: HAND.relaxed, R: HAND.relaxed },
  };
};

export const ANIMATIONS = [
  { id: 'idle', name: 'Idle breathing', loop: true, keys: [
    [0, P('stand')],
    [1.6, tweak('stand', { rot: { chest: [-3, 0, -2], head: [-2, 3, 3] }, hips: [0.025, 0.004, 0] })],
    [3.2, P('stand')] ] },
  { id: 'sly-idle', name: 'Sly idle', loop: true, keys: [
    [0, P('sly')],
    [1.4, tweak('sly', { rot: { hips: [0, -10, 8], chest: [-5, 9, -5], head: [-2, -16, 10] } })],
    [2.8, P('sly')] ] },
  { id: 'wave', name: 'Wave hello', loop: true, keys: [
    [0, P('wave')],
    [0.3, tweak('wave', { dir: { lowerArmR: [0.35, 0.95, 0.1] } })],
    [0.6, P('wave')],
    [0.9, tweak('wave', { dir: { lowerArmR: [0.35, 0.95, 0.1] } })],
    [1.2, P('wave')] ] },
  { id: 'bounce', name: 'Fighting bounce', loop: true, keys: [
    [0, P('ready')],
    [0.35, tweak('ready', { hips: [0, -0.14, 0] })],
    [0.7, P('ready')] ] },
  { id: 'kickcombo', name: 'High kick', loop: false, keys: [
    [0, P('ready')],
    [0.35, tweak('ready', { dir: { upperLegL: [0.1, 0.1, 1], lowerLegL: [0.05, -1, 0.1] }, abs: { footL: [-20, 0, 0] } })],
    [0.55, P('kick')],
    [0.85, P('kick')],
    [1.1, tweak('ready', { dir: { upperLegL: [0.1, 0.1, 1], lowerLegL: [0.05, -1, 0.1] } })],
    [1.5, P('ready')] ] },
  { id: 'spinkick', name: 'Spin kick', loop: false, keys: [
    [0, P('ready')],
    [0.3, tweak('ready', { rot: { hips: [0, 20, 0], chest: [6, 30, 0] } })],
    [0.6, P('spin')],
    [0.9, P('spin')],
    [1.3, P('ready')] ] },
  { id: 'walk', name: 'Walk in place', loop: true, keys: [
    [0, walk('L')], [0.3, pass('L')], [0.6, walk('R')], [0.9, pass('R')], [1.2, walk('L')] ] },
  { id: 'secret', name: 'Shh, then wink', loop: false, keys: [
    [0, P('stand')], [0.6, tweak('shh', { morphs: { wink: 0 } })], [1.0, P('shh')], [2.2, P('shh')], [2.8, P('sly')] ] },
  { id: 'flip', name: 'Jump and land', loop: false, keys: [
    [0, P('stand')],
    [0.35, tweak('ready', { hips: [0, -0.22, 0], rot: { hips: [0, 0, 0], spine: [25, 0, 0] } })],
    [0.7, P('jump')],
    [1.05, tweak('jump', { hips: [0, 0.2, 0], dir: { upperLegL: [0.1, -0.8, 0.5], lowerLegL: [0.05, -1, -0.1], upperLegR: [-0.1, -0.8, 0.5], lowerLegR: [-0.05, -1, -0.1] } })],
    [1.3, tweak('prowl', { hips: [0, -0.3, 0] })],
    [1.9, P('sly')] ] },
];

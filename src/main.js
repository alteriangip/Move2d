import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { TransformControls } from 'three/addons/controls/TransformControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { OutlineEffect } from 'three/addons/effects/OutlineEffect.js';
import { detectRig, collectBones, Poser, SLOTS, SLOT_LABEL, FINGERS } from './rig.js';
import { POSES, ANIMATIONS, applyPose, mirrorPose } from './poses.js';
import { Face } from './face.js';
import { Timeline } from './timeline.js';
import { putFile, getFile, local, saveFile } from './storage.js';

const $ = id => document.getElementById(id);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
const TARGET_HEIGHT = 1.6;

// ---------- three.js setup ----------------------------------------------------------------------
const canvas = $('view');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.setClearColor(0x000000, 0);
const outline = new OutlineEffect(renderer, { defaultThickness: 0.0035, defaultColor: [0.08, 0.05, 0.1], defaultAlpha: 0.9 });

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(32, 1, 0.01, 100);
camera.position.set(0, 1.0, 4.2);
const orbit = new OrbitControls(camera, canvas);
orbit.target.set(0, 0.85, 0);
orbit.enableDamping = true;
orbit.dampingFactor = 0.12;
orbit.minDistance = 0.2; orbit.maxDistance = 20;

const hemi = new THREE.HemisphereLight(0xfff2f8, 0x403a58, 1.6);
scene.add(hemi);
const sun = new THREE.DirectionalLight(0xffffff, 2.2);
sun.castShadow = true;
sun.shadow.mapSize.set(1024, 1024);
Object.assign(sun.shadow.camera, { left: -1.5, right: 1.5, top: 2.2, bottom: -0.5, near: 0.1, far: 12 });
sun.shadow.bias = -0.0005;
scene.add(sun, sun.target);
const rim = new THREE.DirectionalLight(0x9fdcff, 0.9);
rim.position.set(-2, 2.5, -3);
scene.add(rim);

const floor = new THREE.Group();
const shadowFloor = new THREE.Mesh(new THREE.CircleGeometry(3, 48), new THREE.ShadowMaterial({ opacity: 0.32 }));
shadowFloor.rotation.x = -Math.PI / 2; shadowFloor.receiveShadow = true;
const ring = new THREE.Mesh(new THREE.RingGeometry(0.55, 0.57, 64), new THREE.MeshBasicMaterial({ color: 0xff5d8f, transparent: true, opacity: 0.45 }));
ring.rotation.x = -Math.PI / 2; ring.position.y = 0.002;
floor.add(shadowFloor, ring);
scene.add(floor);

const gizmo = new TransformControls(camera, canvas);
gizmo.setSize(0.9);
gizmo.setSpace('local');
scene.add(gizmo.getHelper());

// ---------- app state ----------------------------------------------------------------------------
const state = {
  model: null, poser: null, face: null, bones: [], modelKey: '', modelName: '',
  selected: null, mode: 'rotate', showJoints: true, showAll: false,
  hands: { L: { ...zeroHand() }, R: { ...zeroHand() } },
  tl: new Timeline(), time: 0, playing: false, activePose: null,
  undo: [], redo: [], originalMats: new Map(),
};
function zeroHand() { return { thumb: 0, index: 0, middle: 0, ring: 0, little: 0, spread: 0 }; }

const markers = new THREE.Group();
markers.renderOrder = 999;
scene.add(markers);
const ikTarget = new THREE.Object3D();
scene.add(ikTarget);

// ---------- helpers --------------------------------------------------------------------------------
let toastTimer;
function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), 2200); }
function busy(on, text = 'Loading…') { $('busy').hidden = !on; $('busyText').textContent = text; }
const slotOf = bone => { if (!state.poser) return null; for (const [k, b] of Object.entries(state.poser.map)) if (b === bone) return k; return null; };
const boneLabel = bone => { const s = slotOf(bone); return s ? SLOT_LABEL(s) : bone.name; };

// ---------- loading ------------------------------------------------------------------------------
async function loadBlob(blob, name, { save = true } = {}) {
  busy(true, 'Opening ' + name + '…');
  try {
    let buf = await blob.arrayBuffer();
    let ext = name.toLowerCase().split('.').pop();
    if (ext === 'zip') {
      const { unzipSync } = await import('three/addons/libs/fflate.module.js');
      const files = unzipSync(new Uint8Array(buf));
      const inner = Object.keys(files).find(k => /\.(glb|vrm|fbx|blend)$/i.test(k) && !k.startsWith('__MACOSX'));
      if (!inner) throw new Error('No .glb, .vrm, .fbx or .blend inside that .zip.');
      buf = files[inner].slice().buffer; ext = inner.toLowerCase().split('.').pop();
    }
    let root;
    if (ext === 'fbx') root = new FBXLoader().parse(buf, '');
    else if (['glb', 'gltf', 'vrm'].includes(ext)) root = (await new GLTFLoader().parseAsync(buf, '')).scene;
    else if (ext === 'blend' || /^blend\d+$/.test(ext)) {
      const { blendToThree } = await import('./blend/toThree.js');
      root = (await blendToThree(buf, { onProgress: t => busy(true, t + '…') })).root;
    }
    else throw new Error('Unsupported file type .' + ext + '. Use .blend, .glb, .gltf, .vrm, .fbx or a .zip of one.');
    setModel(root, name);
    if (save) await putFile('model', blob, name).catch(() => toast('Could not keep the model for next time (storage full).'));
  } catch (e) {
    console.error(e);
    toast(e.message || 'Could not open that file.');
  } finally { busy(false); }
}

function setModel(root, name) {
  if (state.model) { scene.remove(state.model); disposeTree(state.model); }
  gizmo.detach();
  state.originalMats.clear();

  // Normalise size and stand on the floor.
  const holder = new THREE.Group();
  holder.add(root);
  root.updateMatrixWorld(true);
  let box = new THREE.Box3().setFromObject(root, true);
  const h = box.getSize(new THREE.Vector3()).y || 1;
  holder.scale.setScalar(TARGET_HEIGHT / h);
  holder.updateMatrixWorld(true);
  box = new THREE.Box3().setFromObject(holder, true);
  const c = box.getCenter(new THREE.Vector3());
  holder.position.set(-c.x, -box.min.y, -c.z);
  holder.updateMatrixWorld(true);

  root.traverse(o => {
    if (o.isMesh) {
      o.castShadow = true; o.receiveShadow = false; o.frustumCulled = false;
      state.originalMats.set(o, o.material);
    }
  });
  scene.add(holder);
  state.model = holder;
  state.modelName = name;
  state.bones = collectBones(holder);
  // Centre on the hips rather than the bounding box, which a tail, cape or weapon can skew.
  const hips = detectRig(state.bones).hips;
  if (hips) {
    const p = hips.getWorldPosition(new THREE.Vector3());
    holder.position.x -= p.x; holder.position.z -= p.z;
    holder.updateMatrixWorld(true);
  }
  state.modelKey = 'rig:' + state.bones.length + ':' + state.bones.slice(0, 6).map(b => b.name).join('|');
  buildPoser();
  state.face = new Face(holder);
  applyShading($('shading').value);
  frameCamera();
  $('empty').hidden = true;
  $('modebar').hidden = false;
  $('modelName').textContent = name;
  $('title').textContent = name.replace(/\.[^.]+$/, '');
  state.tl = new Timeline();
  state.undo = []; state.redo = [];
  buildFaceUI(); syncTimelineUI(); renderMyAnims();
  select(null);
}

function buildPoser() {
  const overrides = local.get(state.modelKey, {});
  const map = detectRig(state.bones, overrides);
  state.poser = state.bones.length ? new Poser(state.model, state.bones, map) : null;
  buildMarkers(); buildRigUI(); fillBoneSelect();
  if (!state.bones.length) toast('This model has no skeleton, so it can be viewed but not posed.');
}

function disposeTree(o) {
  o.traverse(n => {
    if (n.geometry) n.geometry.dispose();
    if (n.material) (Array.isArray(n.material) ? n.material : [n.material]).forEach(m => { for (const v of Object.values(m)) if (v?.isTexture) v.dispose(); m.dispose(); });
  });
}

function frameCamera() {
  orbit.target.set(0, TARGET_HEIGHT * 0.55, 0);
  camera.position.set(0, TARGET_HEIGHT * 0.62, TARGET_HEIGHT * 2.6);
  // char faces +Z when its frame says so; put the camera in front of her.
  if (state.poser) {
    const f = state.poser.fwd.clone().setY(0).normalize();
    if (f.lengthSq() > 0.5) camera.position.set(f.x * TARGET_HEIGHT * 2.6, TARGET_HEIGHT * 0.62, f.z * TARGET_HEIGHT * 2.6);
  }
  orbit.update();
}

// ---------- shading ------------------------------------------------------------------------------
const toonRamp = (() => {
  const t = new THREE.DataTexture(new Uint8Array([110, 110, 200, 255]), 4, 1, THREE.RedFormat);
  t.minFilter = t.magFilter = THREE.NearestFilter; t.needsUpdate = true; return t;
})();
const converted = new Map();
function convertMat(m, kind) {
  const key = m.uuid + kind;
  if (converted.has(key)) return converted.get(key);
  const common = {
    map: m.map || null, color: m.color ? m.color.clone() : new THREE.Color(1, 1, 1), transparent: m.transparent, opacity: m.opacity,
    alphaTest: m.alphaTest, side: m.side, alphaMap: m.alphaMap || null, depthWrite: m.depthWrite, name: m.name,
  };
  let out;
  if (kind === 'toon') out = new THREE.MeshToonMaterial({ ...common, gradientMap: toonRamp, normalMap: m.normalMap || null, emissive: m.emissive?.clone() || new THREE.Color(0), emissiveMap: m.emissiveMap || null });
  else out = new THREE.MeshBasicMaterial(common);
  out.userData.outlineParameters = m.userData?.outlineParameters;
  converted.set(key, out);
  return out;
}
function applyShading(kind) {
  if (!state.model) return;
  for (const [mesh, orig] of state.originalMats) {
    if (kind === 'standard') { mesh.material = orig; continue; }
    mesh.material = Array.isArray(orig) ? orig.map(m => convertMat(m, kind)) : convertMat(orig, kind);
  }
  hemi.intensity = kind === 'toon' ? 1.9 : 1.6;
}

// ---------- joints, selection, gizmo -------------------------------------------------------------
const dotGeo = new THREE.SphereGeometry(1, 12, 8);
const dotMats = {
  L: new THREE.MeshBasicMaterial({ color: 0xff5d8f, depthTest: false, transparent: true, opacity: 0.9 }),
  R: new THREE.MeshBasicMaterial({ color: 0x6fd6ff, depthTest: false, transparent: true, opacity: 0.9 }),
  C: new THREE.MeshBasicMaterial({ color: 0xffffff, depthTest: false, transparent: true, opacity: 0.9 }),
  X: new THREE.MeshBasicMaterial({ color: 0xc9a6ff, depthTest: false, transparent: true, opacity: 0.7 }),
  S: new THREE.MeshBasicMaterial({ color: 0xffe066, depthTest: false }),
};
function buildMarkers() {
  markers.clear();
  if (!state.poser) return;
  const mapped = new Set(Object.values(state.poser.map));
  const showSlots = SLOTS.filter(s => state.poser.map[s] && !/[23][LR]$/.test(s)); // first finger joint only, to keep hands tidy
  const add = (bone, kind, r) => {
    const m = new THREE.Mesh(dotGeo, dotMats[kind]);
    m.scale.setScalar(r); m.renderOrder = 999; m.userData = { bone, kind };
    markers.add(m);
  };
  for (const s of showSlots) add(state.poser.map[s], /L$/.test(s) ? 'L' : /R$/.test(s) ? 'R' : 'C', /\d/.test(s) ? 0.007 : 0.014);
  if (state.showAll) for (const b of state.bones) if (!mapped.has(b) && b.parent?.isBone) add(b, 'X', 0.008);
}
function updateMarkers() {
  markers.visible = state.showJoints && !state.playing;
  if (!markers.visible) return;
  for (const m of markers.children) {
    m.userData.bone.getWorldPosition(m.position);
    m.material = m.userData.bone === state.selected ? dotMats.S : dotMats[m.userData.kind];
  }
}

function select(bone) {
  state.selected = bone;
  $('selName').textContent = bone ? boneLabel(bone) : 'Tap a joint to pose';
  $('boneSelect').value = bone ? bone.name : '';
  const limb = bone && limbOf(bone);
  $$('#modebar [data-mode]').forEach(b => {
    if (b.dataset.mode === 'ik') b.disabled = !limb;
  });
  if (state.mode === 'ik' && !limb) setMode('rotate', false);
  attachGizmo();
  syncSliders();
}
function limbOf(bone) {
  const s = slotOf(bone); if (!s) return null;
  const m = s.match(/^(upperArm|lowerArm|hand|upperLeg|lowerLeg|foot)([LR])$/);
  if (!m) return null;
  return { side: m[2], limb: /Arm|hand/.test(m[1]) ? 'arm' : 'leg' };
}
function setMode(mode, reattach = true) {
  state.mode = mode;
  $$('#modebar [data-mode]').forEach(b => b.classList.toggle('on', b.dataset.mode === mode));
  if (reattach) attachGizmo();
}
function attachGizmo() {
  gizmo.detach();
  if (!state.poser || state.playing) return;
  if (state.mode === 'move') {
    const h = state.poser.map.hips || state.bones[0];
    if (h) { gizmo.setMode('translate'); gizmo.setSpace('world'); gizmo.attach(h); }
    return;
  }
  const bone = state.selected; if (!bone) return;
  if (state.mode === 'ik') {
    const l = limbOf(bone); if (!l) return;
    const end = state.poser.map[(l.limb === 'arm' ? 'hand' : 'foot') + l.side];
    end.getWorldPosition(ikTarget.position);
    ikTarget.userData = l;
    gizmo.setMode('translate'); gizmo.setSpace('world'); gizmo.attach(ikTarget);
    return;
  }
  gizmo.setMode('rotate'); gizmo.setSpace('local'); gizmo.attach(bone);
}
gizmo.addEventListener('dragging-changed', e => {
  orbit.enabled = !e.value;
  if (e.value) pushUndo();
  else { afterEdit(); }
});
gizmo.addEventListener('objectChange', () => {
  if (gizmo.object === ikTarget && state.poser) state.poser.solveIK(ikTarget.userData.side, ikTarget.userData.limb, ikTarget.position);
  else state.model?.updateMatrixWorld(true);
  syncSliders();
});

// Tap-to-select: nearest joint on screen within reach of a finger.
let down = null;
canvas.addEventListener('pointerdown', e => { down = { x: e.clientX, y: e.clientY, t: performance.now() }; });
canvas.addEventListener('pointerup', e => {
  if (!down || gizmo.dragging) return;
  const moved = Math.hypot(e.clientX - down.x, e.clientY - down.y);
  if (moved > 8 || performance.now() - down.t > 500 || !markers.visible) { down = null; return; }
  down = null;
  const rect = canvas.getBoundingClientRect();
  let best = null, bestD = (e.pointerType === 'touch' ? 34 : 20);
  const v = new THREE.Vector3();
  for (const m of markers.children) {
    v.copy(m.position).project(camera);
    if (v.z > 1) continue;
    const sx = (v.x + 1) / 2 * rect.width, sy = (1 - v.y) / 2 * rect.height;
    const d = Math.hypot(sx - (e.clientX - rect.left), sy - (e.clientY - rect.top));
    if (d < bestD) { bestD = d; best = m.userData.bone; }
  }
  if (best) { select(best); if (!$('sheet').querySelector('[data-panel="edit"].on') && !isLandscape()) openTab('edit'); }
});
const isLandscape = () => matchMedia('(orientation: landscape) and (min-width: 900px)').matches;

// ---------- sliders ----------------------------------------------------------------------------
const axes = ['rx', 'ry', 'rz'];
function syncSliders() {
  const b = state.selected;
  axes.forEach(id => { $(id).disabled = !b; });
  if (!b || !state.poser) { axes.forEach(id => { $(id).value = 0; $(id + 'v').textContent = ''; }); return; }
  const e = state.poser.worldRotToChar(state.poser.ownDelta(b));
  axes.forEach((id, i) => { $(id).value = e[i].toFixed(1); $(id + 'v').textContent = Math.round(e[i]) + '°'; });
}
axes.forEach(id => {
  $(id).addEventListener('pointerdown', pushUndo);
  $(id).addEventListener('input', () => {
    const b = state.selected; if (!b || !state.poser) return;
    const e = axes.map(a => +$(a).value);
    state.poser.setOwnDelta(b, state.poser.charRot(e));
    $(id + 'v').textContent = Math.round($(id).value) + '°';
  });
  $(id).addEventListener('change', afterEdit);
});
$('btnResetBone').onclick = () => { if (!state.selected) return; pushUndo(); state.poser.resetBone(state.selected); afterEdit(); syncSliders(); };
function fillBoneSelect() {
  const sel = $('boneSelect');
  sel.textContent = '';
  sel.append(new Option('Choose a bone…', ''));
  if (!state.poser) return;
  const mapped = new Set();
  const g1 = document.createElement('optgroup'); g1.label = 'Body';
  for (const s of SLOTS) { const b = state.poser.map[s]; if (b) { mapped.add(b); g1.append(new Option(SLOT_LABEL(s), b.name)); } }
  const g2 = document.createElement('optgroup'); g2.label = 'Other bones (hair, tail, cloth)';
  for (const b of state.bones) if (!mapped.has(b)) g2.append(new Option(b.name, b.name));
  sel.append(g1, g2);
}
$('boneSelect').onchange = e => select(state.bones.find(b => b.name === e.target.value) || null);
$('chkAllBones').onchange = e => { state.showAll = e.target.checked; buildMarkers(); };

// ---------- edits, undo, autokey -------------------------------------------------------------------
function capture() { return { pose: state.poser.snapshot(), face: state.face?.snapshot() || {} }; }
function restoreCap(c) { state.poser.restore(c.pose); state.face?.restore(c.face); syncSliders(); syncFaceUI(); }
function pushUndo() { if (!state.poser) return; state.undo.push(capture()); if (state.undo.length > 60) state.undo.shift(); state.redo = []; }
function afterEdit() {
  state.activePose = null; markPose();
  if ($('tlAuto').checked && !$('timeline').hidden) { state.tl.setKey(state.time, ...Object.values(capture())); syncTimelineUI(); }
}
$('btnUndo').onclick = () => { const c = state.undo.pop(); if (!c) return; state.redo.push(capture()); restoreCap(c); };
$('btnRedo').onclick = () => { const c = state.redo.pop(); if (!c) return; state.undo.push(capture()); restoreCap(c); };

// ---------- poses panel ---------------------------------------------------------------------------
function renderPoseGrid() {
  const grid = $('poseGrid'); grid.textContent = '';
  let group = '';
  for (const p of POSES) {
    if (p.group !== group) { group = p.group; const h = document.createElement('h3'); h.textContent = group; grid.append(h); }
    const b = document.createElement('button');
    b.className = 'pose'; b.textContent = p.name; b.dataset.id = p.id;
    b.onclick = () => usePreset(p);
    grid.append(b);
  }
}
function markPose() { $$('.pose').forEach(b => b.classList.toggle('on', b.dataset.id === state.activePose)); }
function usePreset(p) {
  if (!state.poser) return toast('Load a model first.');
  pushUndo();
  const def = $('chkMirrorPreset').checked ? mirrorPose(p) : p;
  applyPose(state.poser, def, state.face);
  for (const s of ['L', 'R']) state.hands[s] = { ...zeroHand(), ...(def.fingers?.[s] || {}) };
  syncHandsUI(); syncSliders(); syncFaceUI();
  afterEdit();
  state.activePose = p.id; markPose();
}
$('btnMirror').onclick = () => {
  if (!state.poser) return;
  pushUndo();
  state.poser.restore(state.poser.mirrorSnapshot(state.poser.snapshot()));
  const h = state.hands.L; state.hands.L = state.hands.R; state.hands.R = h; syncHandsUI();
  afterEdit(); syncSliders();
};
$('btnSavePose').onclick = () => {
  if (!state.poser) return;
  const list = local.get('poses', []);
  const name = 'Pose ' + (list.length + 1);
  list.unshift({ name, ...capture(), hands: state.hands, at: Date.now() });
  local.set('poses', list) ? toast('Saved as ' + name) : toast('Storage is full. Delete a saved pose first.');
  renderMyPoses();
};
function renderMyPoses() {
  const el = $('myPoses'); el.textContent = '';
  const list = local.get('poses', []);
  if (!list.length) { el.innerHTML = '<p class="hint">Poses you save show up here.</p>'; return; }
  list.forEach((p, i) => el.append(listItem(p.name, () => {
    if (!state.poser) return; pushUndo(); restoreCap(p); if (p.hands) { state.hands = structuredClone(p.hands); syncHandsUI(); } afterEdit();
  }, n => { list[i].name = n; local.set('poses', list); }, () => { list.splice(i, 1); local.set('poses', list); renderMyPoses(); })));
}
function listItem(name, onUse, onRename, onDelete) {
  const row = document.createElement('div'); row.className = 'item';
  const label = document.createElement('span'); label.textContent = name;
  const use = button('Use', 'ghost small', onUse);
  const ren = button('Rename', 'ghost small', () => {
    const inp = Object.assign(document.createElement('input'), { type: 'text', value: name });
    label.replaceWith(inp); inp.focus(); inp.select();
    const done = () => { const v = inp.value.trim() || name; onRename(v); label.textContent = v; inp.replaceWith(label); };
    inp.onblur = done; inp.onkeydown = e => { if (e.key === 'Enter') inp.blur(); };
  });
  const del = button('Delete', 'ghost small', () => {
    if (del.dataset.armed) return onDelete();
    del.dataset.armed = '1'; del.textContent = 'Sure?'; setTimeout(() => { delete del.dataset.armed; del.textContent = 'Delete'; }, 2500);
  });
  row.append(label, use, ren, del);
  return row;
}
function button(text, cls, onclick) { const b = document.createElement('button'); b.className = cls; b.textContent = text; b.onclick = onclick; return b; }

// ---------- hands ----------------------------------------------------------------------------------
const HAND_SHAPES = {
  Relaxed: { thumb: 0.25, index: 0.2, middle: 0.28, ring: 0.34, little: 0.4, spread: 0.1 },
  Open: { thumb: 0, index: 0, middle: 0, ring: 0, little: 0, spread: 0.6 },
  Fist: { thumb: 0.9, index: 1, middle: 1, ring: 1, little: 1, spread: 0 },
  Point: { thumb: 0.8, index: 0, middle: 1, ring: 1, little: 1, spread: 0 },
  Peace: { thumb: 0.9, index: 0, middle: 0, ring: 1, little: 1, spread: 0.9 },
  Claw: { thumb: 0.4, index: 0.55, middle: 0.55, ring: 0.6, little: 0.6, spread: 0.7 },
};
function buildHandsUI() {
  for (const side of ['L', 'R']) {
    const box = document.querySelector(`.hands [data-side="${side}"]`);
    const shapes = box.querySelector('.shapes'); shapes.textContent = '';
    for (const [n, v] of Object.entries(HAND_SHAPES)) shapes.append(button(n, 'chip', () => { pushUndo(); state.hands[side] = { ...v }; applyHand(side); syncHandsUI(); afterEdit(); }));
    const sl = box.querySelector('.fsliders'); sl.textContent = '';
    for (const f of [...FINGERS, 'spread']) {
      const id = `f_${side}_${f}`;
      const row = document.createElement('div'); row.className = 'slider';
      row.innerHTML = `<label for="${id}">${f[0].toUpperCase() + f.slice(1)}</label><input id="${id}" type="range" min="${f === 'spread' ? -1 : 0}" max="1" step="0.01"><output></output>`;
      const inp = row.querySelector('input');
      inp.addEventListener('pointerdown', pushUndo);
      inp.oninput = () => { state.hands[side][f] = +inp.value; applyHand(side); row.querySelector('output').textContent = Math.round(inp.value * 100) + '%'; };
      inp.onchange = afterEdit;
      sl.append(row);
    }
  }
  syncHandsUI();
}
function applyHand(side) { state.poser?.setFingers(side, state.hands[side]); }
function syncHandsUI() {
  for (const side of ['L', 'R']) for (const f of [...FINGERS, 'spread']) {
    const inp = $(`f_${side}_${f}`); if (!inp) continue;
    inp.value = state.hands[side][f] || 0;
    inp.nextElementSibling.textContent = Math.round(inp.value * 100) + '%';
  }
}

// ---------- face -----------------------------------------------------------------------------------
function buildFaceUI() {
  const q = $('faceQuick'); q.textContent = '';
  const list = $('faceList'); list.textContent = '';
  const face = state.face;
  if (!face || !face.names.length) { list.innerHTML = '<p class="hint">This model has no face shape keys.</p>'; return; }
  for (const [label, meaning] of [['Smile', 'smile'], ['Wink', 'wink'], ['Blink', 'blink'], ['Open mouth', 'mouthA'], ['Surprised', 'surprised'], ['Angry', 'angry']]) {
    const n = face.find(meaning); if (!n) continue;
    q.append(button(label, 'chip', () => { pushUndo(); face.set(n, face.values[n] > 0.5 ? 0 : 1); syncFaceUI(); afterEdit(); }));
  }
  q.append(button('Neutral', 'chip', () => { pushUndo(); face.reset(); syncFaceUI(); afterEdit(); }));
  for (const n of face.names) {
    const row = document.createElement('div'); row.className = 'item'; row.dataset.name = n.toLowerCase();
    const label = document.createElement('span'); label.textContent = n;
    const inp = Object.assign(document.createElement('input'), { type: 'range', min: 0, max: 1, step: 0.01, value: face.values[n] });
    inp.setAttribute('aria-label', n); inp.dataset.morph = n;
    inp.addEventListener('pointerdown', pushUndo);
    inp.oninput = () => face.set(n, +inp.value);
    inp.onchange = afterEdit;
    row.append(label, inp); list.append(row);
  }
}
function syncFaceUI() { if (!state.face) return; $$('#faceList input[data-morph]').forEach(i => { i.value = state.face.values[i.dataset.morph] || 0; }); }
$('faceSearch').oninput = e => { const q = e.target.value.toLowerCase(); $$('#faceList .item').forEach(r => { r.hidden = q && !r.dataset.name.includes(q); }); };

// ---------- timeline -------------------------------------------------------------------------------
function syncTimelineUI() {
  const tl = state.tl;
  $('tlScrub').max = tl.duration;
  $('tlDur').value = tl.duration;
  $('tlLoop').checked = tl.loop; $('tlSmooth').checked = tl.smooth;
  const keys = $('tlKeys'); keys.textContent = '';
  for (const k of tl.keys) { const i = document.createElement('i'); i.style.left = (k.t / tl.duration * 100) + '%'; if (Math.abs(k.t - state.time) < 0.02) i.className = 'cur'; keys.append(i); }
  $('tlTime').textContent = state.time.toFixed(2) + ' s';
  $('tlKey').textContent = tl.keyAt(state.time) ? 'Update key' : '+ Key';
  $('tlDel').disabled = !tl.keyAt(state.time);
}
function seek(t) {
  state.time = Math.max(0, Math.min(state.tl.duration, t));
  $('tlScrub').value = state.time;
  if (state.tl.keys.length && state.poser) { state.tl.evaluate(state.time, state.poser, state.face); syncSliders(); syncFaceUI(); }
  syncTimelineUI();
}
$('tlScrub').oninput = e => { if (state.playing) togglePlay(false); seek(+e.target.value); };
$('tlKey').onclick = () => { if (!state.poser) return; const c = capture(); state.tl.setKey(state.time, c.pose, c.face); syncTimelineUI(); toast('Key at ' + state.time.toFixed(2) + ' s'); };
$('tlDel').onclick = () => { state.tl.removeKey(state.time); syncTimelineUI(); };
$('tlNext').onclick = () => { const k = state.tl.next(state.time); if (k) seek(k.t); };
$('tlPrev').onclick = () => { const k = state.tl.prev(state.time); if (k) seek(k.t); };
$('tlPlay').onclick = () => togglePlay();
$('tlDur').onchange = e => { state.tl.duration = Math.max(0.2, +e.target.value || 2); seek(Math.min(state.time, state.tl.duration)); };
$('tlLoop').onchange = e => { state.tl.loop = e.target.checked; };
$('tlSmooth').onchange = e => { state.tl.smooth = e.target.checked; };
$('btnAnimClear').onclick = () => { state.tl.keys = []; syncTimelineUI(); toast('Keys cleared'); };
function togglePlay(on = !state.playing) {
  if (on && state.tl.keys.length < 2) return toast('Add at least two keys to play.');
  state.playing = on;
  $('tlPlay').textContent = on ? '❚❚' : '▶';
  $('tlPlay').setAttribute('aria-label', on ? 'Pause' : 'Play');
  if (on && state.time >= state.tl.duration - 0.01) state.time = 0;
  attachGizmo();
  if (!on) { syncSliders(); syncFaceUI(); syncTimelineUI(); }
}
function fillAnimPresets() {
  const sel = $('animPreset');
  for (const a of ANIMATIONS) sel.append(new Option(a.name, a.id));
  sel.onchange = () => {
    const a = ANIMATIONS.find(x => x.id === sel.value); sel.value = '';
    if (!a || !state.poser) return;
    const tl = new Timeline();
    for (const [t, pose] of a.keys) { applyPose(state.poser, pose, state.face); const c = capture(); tl.setKey(t, c.pose, c.face); }
    tl.duration = a.keys.at(-1)[0]; tl.loop = a.loop;
    state.tl = tl; state.time = 0;
    syncTimelineUI(); seek(0); togglePlay(true);
  };
}
$('btnAnimSave').onclick = () => {
  if (!state.tl.keys.length) return toast('No keys to save yet.');
  const list = local.get('anims', []);
  const name = 'Animation ' + (list.length + 1);
  list.unshift({ name, data: state.tl.toJSON(), at: Date.now() });
  local.set('anims', list) ? toast('Saved as ' + name) : toast('Storage is full. Delete a saved animation first.');
  renderMyAnims();
};
function renderMyAnims() {
  const el = $('myAnims'); el.textContent = '';
  const list = local.get('anims', []);
  if (!list.length) { el.innerHTML = '<p class="hint">Saved animations show up here.</p>'; return; }
  list.forEach((a, i) => el.append(listItem(a.name, () => { state.tl = new Timeline(); state.tl.load(a.data); seek(0); },
    n => { list[i].name = n; local.set('anims', list); }, () => { list.splice(i, 1); local.set('anims', list); renderMyAnims(); })));
}
$('btnAnimJson').onclick = () => saveFile(new Blob([JSON.stringify({ app: 'move2d', ...state.tl.toJSON() })], { type: 'application/json' }), 'animation.json');
$('btnAnimImport').onclick = () => $('jsonPick').click();
$('jsonPick').onchange = async e => {
  const f = e.target.files[0]; e.target.value = ''; if (!f) return;
  try { const o = JSON.parse(await f.text()); state.tl = new Timeline(); state.tl.load(o); seek(0); toast('Animation loaded'); }
  catch { toast('That file is not a Move2D animation.'); }
};
$('btnAnimExport').onclick = async () => {
  if (!state.model) return;
  busy(true, 'Exporting…');
  try {
    const was = capture();
    const clips = state.tl.keys.length >= 2 ? [state.tl.toClip(state.poser, state.face)] : [];
    restoreCap(was);
    gizmo.detach();
    const root = state.model.children[0];
    const glb = await new GLTFExporter().parseAsync(root, { binary: true, animations: clips, onlyVisible: true });
    await saveFile(new Blob([glb], { type: 'model/gltf-binary' }), (state.modelName.replace(/\.[^.]+$/, '') || 'model') + (clips.length ? '-animated' : '-posed') + '.glb');
  } catch (e) { console.error(e); toast('Export failed: ' + e.message); }
  finally { busy(false); attachGizmo(); }
};

// ---------- scene panel ----------------------------------------------------------------------------
$('shading').onchange = e => { applyShading(e.target.value); local.set('shading', e.target.value); };
$('chkOutline').onchange = e => local.set('outline', e.target.checked);
$('chkFloor').onchange = e => { floor.visible = e.target.checked; };
$('backdrop').onchange = e => { $('stage').dataset.bg = e.target.value; local.set('backdrop', e.target.value); };
$('light').oninput = e => { placeSun(+e.target.value); e.target.nextElementSibling.textContent = e.target.value + '°'; };
function placeSun(deg) { const r = THREE.MathUtils.degToRad(deg); sun.position.set(Math.sin(r) * 3, 4, Math.cos(r) * 3); sun.target.position.set(0, 0.8, 0); }
$('btnJoints').onclick = e => { state.showJoints = !state.showJoints; e.target.classList.toggle('on', state.showJoints); };
$('btnShot').onclick = () => {
  gizmo.getHelper().visible = false; markers.visible = false;
  render();
  canvas.toBlob(b => { gizmo.getHelper().visible = true; if (b) saveFile(b, 'move2d-' + Date.now() + '.png'); }, 'image/png');
};

function buildRigUI() {
  const info = $('rigInfo'), list = $('rigMap');
  list.textContent = '';
  if (!state.poser) { info.textContent = 'No skeleton found.'; return; }
  const core = ['hips', 'spine', 'head', 'upperArmL', 'lowerArmL', 'handL', 'upperArmR', 'lowerArmR', 'handR', 'upperLegL', 'lowerLegL', 'footL', 'upperLegR', 'lowerLegR', 'footR'];
  const missing = core.filter(s => !state.poser.map[s]);
  const found = SLOTS.filter(s => state.poser.map[s]).length;
  info.textContent = `${state.bones.length} bones, ${found} of ${SLOTS.length} body parts recognised.` + (missing.length ? ' Missing: ' + missing.map(SLOT_LABEL).join(', ') + '. Set them below so the preset poses work.' : '');
  const names = state.bones.map(b => b.name);
  const overrides = local.get(state.modelKey, {});
  for (const s of SLOTS) {
    const row = document.createElement('div'); row.className = 'item';
    const lab = document.createElement('span'); lab.className = 'slot'; lab.textContent = SLOT_LABEL(s);
    const sel = document.createElement('select');
    sel.append(new Option('— none —', ''));
    names.forEach(n => sel.append(new Option(n, n)));
    sel.value = state.poser.map[s]?.name || '';
    sel.setAttribute('aria-label', SLOT_LABEL(s));
    sel.onchange = () => { overrides[s] = sel.value; local.set(state.modelKey, overrides); state.poser.resetAll(); buildPoser(); toast('Skeleton updated'); };
    row.append(lab, sel); list.append(row);
  }
}

// ---------- tabs, files, resize ------------------------------------------------------------------
function openTab(name) {
  $$('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === name));
  $$('.panel').forEach(p => p.classList.toggle('on', p.dataset.panel === name));
  $('timeline').hidden = name !== 'anim' && !state.tl.keys.length;
  if (name === 'anim') syncTimelineUI();
  local.set('tab', name);
}
$$('#tabs button').forEach(b => b.onclick = () => openTab(b.dataset.tab));
$$('[data-action="load"]').forEach(b => b.onclick = () => $('filePick').click());
$('filePick').onchange = e => { const f = e.target.files[0]; e.target.value = ''; if (f) loadBlob(f, f.name); };
$$('#modebar [data-mode]').forEach(b => b.onclick = () => setMode(b.dataset.mode));
$('stage').addEventListener('dragover', e => e.preventDefault());
$('stage').addEventListener('drop', e => { e.preventDefault(); const f = e.dataTransfer.files[0]; if (f) loadBlob(f, f.name); });

function resize() {
  const r = $('stage').getBoundingClientRect();
  renderer.setSize(r.width, r.height, false);
  camera.aspect = r.width / Math.max(1, r.height);
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe($('stage'));

// ---------- loop ---------------------------------------------------------------------------------
const clock = new THREE.Clock();
function render() {
  if ($('chkOutline').checked && $('shading').value !== 'standard') outline.render(scene, camera);
  else renderer.render(scene, camera);
}
function tick() {
  const dt = Math.min(clock.getDelta(), 0.1);
  if (state.playing && state.poser) {
    let t = state.time + dt;
    if (t > state.tl.duration) { if (state.tl.loop) t %= state.tl.duration; else { t = state.tl.duration; togglePlay(false); } }
    state.time = t;
    state.tl.evaluate(t, state.poser, state.face);
    $('tlScrub').value = t; $('tlTime').textContent = t.toFixed(2) + ' s';
  }
  orbit.update();
  updateMarkers();
  render();
  requestAnimationFrame(tick);
}

// ---------- boot -----------------------------------------------------------------------------------
async function boot() {
  $('shading').value = local.get('shading', 'toon');
  $('chkOutline').checked = local.get('outline', true);
  $('backdrop').value = local.get('backdrop', 'dusk');
  $('stage').dataset.bg = $('backdrop').value;
  placeSun(35); $('light').nextElementSibling.textContent = '35°';
  renderPoseGrid(); renderMyPoses(); buildHandsUI(); fillAnimPresets(); renderMyAnims();
  openTab(local.get('tab', 'poses'));
  resize();
  requestAnimationFrame(tick);
  const saved = await getFile('model');
  if (saved) return loadBlob(saved.blob, saved.name, { save: false });
  try {
    const r = await fetch('./models/model.glb');
    if (r.ok && (r.headers.get('content-type') || '').indexOf('text/html') < 0) return loadBlob(await r.blob(), 'model.glb', { save: true });
  } catch { /* no bundled model */ }
}
boot();

// Exposed for debugging in the browser console.
window.move2d = { state, scene, camera, THREE };

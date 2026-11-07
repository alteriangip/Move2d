// Browser converter: .blend -> .glb (zipped, since phones only save allow-listed types).
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { zipSync } from 'three/addons/libs/fflate.module.js';
import { inspectBlend, blendToThree } from '../src/blend/toThree.js';

const $ = id => document.getElementById(id);
let info = null, fileName = '', result = null;
const status = (t, kind = '') => { const s = $('status'); s.textContent = t; s.className = 'msg ' + kind; };
const fmt = n => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
const nextFrame = () => new Promise(r => requestAnimationFrame(() => setTimeout(r, 0)));

async function open(file) {
  if (!file) return;
  fileName = file.name.replace(/\.(blend\d*|zip)$/i, '') || 'model';
  info = null; result = null; $('meshes').hidden = true; $('done').hidden = true; $('go').disabled = true;
  status('Reading ' + file.name + ' (' + fmt(file.size) + ')…', 'busy');
  await nextFrame();
  try {
    info = inspectBlend(await file.arrayBuffer());
  } catch (e) { status(e.message || 'Could not read that file.', 'bad'); return; }
  const list = $('meshList'); list.textContent = '';
  for (const m of info.meshes) {
    const id = 'm_' + list.children.length;
    const row = document.createElement('label'); row.className = 'mesh'; row.htmlFor = id;
    const cb = Object.assign(document.createElement('input'), { type: 'checkbox', id, checked: !m.hidden }); cb.dataset.name = m.name;
    const name = document.createElement('span'); name.className = 'name'; name.textContent = m.name;
    const meta = document.createElement('span'); meta.className = 'meta'; meta.textContent = m.faces.toLocaleString() + ' faces' + (m.hidden ? ' · hidden in the file' : '');
    row.append(cb, name, meta); list.append(row);
    cb.onchange = () => { $('go').disabled = !list.querySelector('input:checked'); };
  }
  $('rigName').textContent = info.armature.name;
  $('blVer').textContent = (info.version / 100).toFixed(2).replace(/0$/, '');
  $('meshes').hidden = false; $('go').disabled = !$('meshList').querySelector('input:checked');
  status('Found the skeleton and ' + info.meshes.length + ' meshes. Pick what to include, then convert.', 'ok');
}

async function convert() {
  if (!info) return;
  const include = [...$('meshList').querySelectorAll('input:checked')].map(i => i.dataset.name);
  $('go').disabled = true; $('done').hidden = true;
  try {
    const built = await blendToThree(info, { include, onProgress: t => status(t + '…', 'busy') });
    status('Packing .glb…', 'busy'); await nextFrame();
    const glb = await new GLTFExporter().parseAsync(built.root, { binary: true, maxTextureSize: 2048 });
    const zip = zipSync({ [fileName + '.glb']: new Uint8Array(glb) }, { level: 0 });
    result = new Blob([zip]);
    $('outName').textContent = fileName + '.zip';
    $('outMeta').textContent = fmt(glb.byteLength) + ' .glb inside · ' + built.info.bones + ' bones · ' + built.info.meshes.length + ' meshes';
    $('done').hidden = false;
    status('Converted. Save the file, then open it in Move2D.', 'ok');
    $('save').focus();
  } catch (e) { console.error(e); status('Conversion failed: ' + (e.message || e), 'bad'); }
  finally { $('go').disabled = false; }
}

async function save() {
  if (!result) return;
  const dl = await window.claude?.use?.('downloads');
  if (!dl) { status('Saving is not available in this view. Open the page in the Claude app or on claude.ai.', 'bad'); return; }
  try { await dl.save({ filename: fileName + '.zip', data: result }); status('Saved. In Move2D tap Choose model and pick ' + fileName + '.zip.', 'ok'); }
  catch (e) {
    if (e?.code === 'declined') status('Save cancelled. Tap Save again when ready.');
    else if (e?.code === 'rate_limited') status('A save prompt is already open. Finish it first.');
    else status('Could not save: ' + (e?.message || e?.code || e), 'bad');
  }
}

$('pick').onclick = () => $('file').click();
$('file').onchange = e => { open(e.target.files[0]); e.target.value = ''; };
const dz = $('drop');
['dragenter', 'dragover'].forEach(t => dz.addEventListener(t, e => { e.preventDefault(); dz.classList.add('over'); }));
['dragleave', 'drop'].forEach(t => dz.addEventListener(t, e => { e.preventDefault(); dz.classList.remove('over'); }));
dz.addEventListener('drop', e => open(e.dataTransfer.files[0]));
$('go').onclick = convert;
$('save').onclick = save;
status('Pick your .blend to start.');

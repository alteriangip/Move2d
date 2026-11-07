// Persistence: the model file in IndexedDB, poses/animations in localStorage, exports via share sheet.
import { Capacitor } from '@capacitor/core';

const DB = 'move2d', STORE = 'files';
function idb() {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
export async function putFile(key, blob, name) {
  const db = await idb();
  await new Promise((res, rej) => { const t = db.transaction(STORE, 'readwrite'); t.objectStore(STORE).put({ blob, name }, key); t.oncomplete = res; t.onerror = () => rej(t.error); });
}
export async function getFile(key) {
  try {
    const db = await idb();
    return await new Promise((res, rej) => { const r = db.transaction(STORE).objectStore(STORE).get(key); r.onsuccess = () => res(r.result || null); r.onerror = () => rej(r.error); });
  } catch { return null; }
}

export const local = {
  get(k, d) { try { const v = localStorage.getItem('move2d.' + k); return v ? JSON.parse(v) : d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem('move2d.' + k, JSON.stringify(v)); return true; } catch { return false; } },
};

function toBase64(blob) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1]); r.onerror = () => rej(r.error); r.readAsDataURL(blob); });
}

/** Hand a generated file to the user: share sheet on phones, download in a browser. */
export async function saveFile(blob, filename) {
  if (Capacitor.isNativePlatform()) {
    const { Filesystem, Directory } = await import('@capacitor/filesystem');
    const { Share } = await import('@capacitor/share');
    const data = await toBase64(blob);
    const { uri } = await Filesystem.writeFile({ path: filename, data, directory: Directory.Cache });
    await Share.share({ title: filename, files: [uri] }).catch(() => Share.share({ title: filename, url: uri }));
    return;
  }
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement('a'), { href: url, download: filename });
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

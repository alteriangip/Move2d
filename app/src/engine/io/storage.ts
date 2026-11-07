/**
 * On-device project storage (IndexedDB).
 *
 * Binary data is stored as ArrayBuffer, never Blob: M0 measured WebKit
 * refusing Blob values in third-party contexts while ArrayBuffer works
 * everywhere (≈940 MB/s write on the iPad).
 */
import type { Asset, Doc, Id } from '../model/types';

export interface ProjectMeta {
  id: Id;
  name: string;
  updatedAt: string;
  width: number;
  height: number;
  layerCount: number;
}

const DB_NAME = 'openlive';
let dbp: Promise<IDBDatabase> | null = null;

function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const r = indexedDB.open(DB_NAME, 1);
    r.onupgradeneeded = () => {
      const d = r.result;
      d.createObjectStore('meta');
      d.createObjectStore('docs');
      d.createObjectStore('assets');
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  return dbp;
}

async function run<T>(stores: string[], mode: IDBTransactionMode, f: (t: IDBTransaction) => IDBRequest<T> | void): Promise<T | undefined> {
  const d = await db();
  return new Promise((resolve, reject) => {
    const t = d.transaction(stores, mode);
    const req = f(t);
    let v: T | undefined;
    if (req) req.onsuccess = () => (v = req.result);
    t.oncomplete = () => resolve(v);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error ?? new Error('Storage transaction aborted'));
  });
}

export async function listProjects(): Promise<ProjectMeta[]> {
  const all = (await run<ProjectMeta[]>(['meta'], 'readonly', (t) => t.objectStore('meta').getAll())) ?? [];
  return all.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}

export async function saveDoc(doc: Doc): Promise<void> {
  const meta: ProjectMeta = {
    id: doc.id,
    name: doc.name,
    updatedAt: doc.updatedAt,
    width: doc.width,
    height: doc.height,
    layerCount: Object.values(doc.nodes).filter((n) => n.kind === 'layer').length,
  };
  await run(['meta', 'docs'], 'readwrite', (t) => {
    t.objectStore('docs').put(doc, doc.id);
    t.objectStore('meta').put(meta, doc.id);
  });
}

export async function putAssets(projectId: Id, assets: Asset[]): Promise<void> {
  if (!assets.length) return;
  await run(['assets'], 'readwrite', (t) => {
    const s = t.objectStore('assets');
    for (const a of assets) s.put(a, `${projectId}/${a.id}`);
  });
}

export async function loadProject(id: Id): Promise<{ doc: Doc; assets: Map<Id, Asset> } | null> {
  const doc = await run<Doc>(['docs'], 'readonly', (t) => t.objectStore('docs').get(id));
  if (!doc) return null;
  const range = IDBKeyRange.bound(`${id}/`, `${id}/￿`);
  const list = (await run<Asset[]>(['assets'], 'readonly', (t) => t.objectStore('assets').getAll(range))) ?? [];
  return { doc, assets: new Map(list.map((a) => [a.id, a])) };
}

export async function deleteProject(id: Id): Promise<void> {
  const range = IDBKeyRange.bound(`${id}/`, `${id}/￿`);
  await run(['meta', 'docs', 'assets'], 'readwrite', (t) => {
    t.objectStore('meta').delete(id);
    t.objectStore('docs').delete(id);
    t.objectStore('assets').delete(range);
  });
}

/** Deletes stored assets no longer referenced by the document (after save). */
export async function pruneAssets(projectId: Id, keep: Set<Id>): Promise<number> {
  const range = IDBKeyRange.bound(`${projectId}/`, `${projectId}/￿`);
  const keys = ((await run<IDBValidKey[]>(['assets'], 'readonly', (t) => t.objectStore('assets').getAllKeys(range))) ?? []) as string[];
  const drop = keys.filter((k) => !keep.has(k.slice(projectId.length + 1)));
  if (drop.length) await run(['assets'], 'readwrite', (t) => drop.forEach((k) => t.objectStore('assets').delete(k)));
  return drop.length;
}

export async function storageEstimate(): Promise<{ usageMB: number; quotaMB: number; persisted: boolean } | null> {
  try {
    const e = await navigator.storage?.estimate?.();
    const persisted = (await navigator.storage?.persisted?.()) ?? false;
    return e ? { usageMB: (e.usage ?? 0) / 1048576, quotaMB: (e.quota ?? 0) / 1048576, persisted } : null;
  } catch {
    return null;
  }
}

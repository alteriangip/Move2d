/**
 * Storage experiment: quota, persistence grant, IndexedDB blob throughput,
 * OPFS availability, and an eviction marker that later visits can check.
 */
import type { Experiment } from './experiment';
import { round, MB } from './experiment';

const DB = 'openlive-m0';

function openDb(): Promise<IDBDatabase> {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore('blobs');
      r.result.createObjectStore('meta');
    };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}

function tx<T>(db: IDBDatabase, store: string, mode: IDBTransactionMode, f: (s: IDBObjectStore) => IDBRequest<T> | void): Promise<T | undefined> {
  return new Promise((res, rej) => {
    const t = db.transaction(store, mode);
    const s = t.objectStore(store);
    const req = f(s);
    let val: T | undefined;
    if (req) req.onsuccess = () => (val = req.result);
    t.oncomplete = () => res(val);
    t.onerror = () => rej(t.error);
    t.onabort = () => rej(t.error);
  });
}

export const storageLab: Experiment = {
  id: 'storage',
  title: 'Storage: quota, persistence, IndexedDB throughput, eviction marker',
  summary: 'Requests persistent storage, writes/reads 80 MB of blobs in IndexedDB, and records a first-seen marker to detect eviction later.',
  async run(ctx) {
    const out: Record<string, unknown> = {};
    try {
      const est = await navigator.storage?.estimate?.();
      out.estimateBefore = est ? { usageMB: round((est.usage ?? 0) / MB), quotaMB: round((est.quota ?? 0) / MB) } : null;
    } catch (e) {
      out.estimateBefore = `error: ${(e as Error).message}`;
    }
    try {
      out.persistedBefore = await navigator.storage?.persisted?.();
      out.persistRequestResult = await navigator.storage?.persist?.();
      out.persistedAfter = await navigator.storage?.persisted?.();
    } catch (e) {
      out.persist = `error: ${(e as Error).message}`;
    }

    try {
      const db = await openDb();
      // Eviction marker: keep across visits.
      const now = Date.now();
      const marker = (await tx<{ firstSeen: number; visits: number }>(db, 'meta', 'readonly', (s) => s.get('marker'))) ?? null;
      const next = { firstSeen: marker?.firstSeen ?? now, visits: (marker?.visits ?? 0) + 1, lastSeen: now };
      await tx(db, 'meta', 'readwrite', (s) => s.put(next, 'marker'));
      out.evictionMarker = {
        firstSeen: new Date(next.firstSeen).toISOString(),
        visits: next.visits,
        daysSinceFirstSeen: round((now - next.firstSeen) / 86400000, 2),
        survivedFromEarlierVisit: !!marker,
      };

      const N = 10,
        SIZE = 8 * MB;
      const chunk = new Uint8Array(SIZE);
      for (let i = 0; i < SIZE; i += 4096) chunk[i] = (i / 4096) & 255; // not trivially compressible pattern
      // Run 1 on the iPad (claude.ai frame) failed storing Blobs; measure Blob and ArrayBuffer separately.
      const variants: [string, () => Blob | ArrayBuffer][] = [
        ['blob', () => new Blob([chunk], { type: 'application/octet-stream' })],
        ['arrayBuffer', () => chunk.slice().buffer],
      ];
      const results: Record<string, unknown> = {};
      for (const [name, make] of variants) {
        try {
          ctx.log(`IndexedDB (${name}): writing 80 MB…`);
          const t0 = performance.now();
          for (let i = 0; i < N; i++) {
            const v = make();
            await tx(db, 'blobs', 'readwrite', (st) => st.put(v, `${name}${i}`));
          }
          const writeMs = performance.now() - t0;
          const t1 = performance.now();
          let readBytes = 0;
          for (let i = 0; i < N; i++) {
            const v = await tx<Blob | ArrayBuffer>(db, 'blobs', 'readonly', (st) => st.get(`${name}${i}`));
            if (v instanceof Blob) readBytes += (await v.arrayBuffer()).byteLength;
            else if (v) readBytes += v.byteLength;
          }
          const readMs = performance.now() - t1;
          results[name] = {
            writeMBps: round((N * SIZE) / MB / (writeMs / 1000), 1),
            readMBps: round(readBytes / MB / (readMs / 1000), 1),
            readBackComplete: readBytes === N * SIZE,
          };
        } catch (e) {
          results[name] = `error: ${(e as Error).name}: ${(e as Error).message}`;
        }
      }
      const est = await navigator.storage?.estimate?.();
      out.estimateWithData = est ? { usageMB: round((est.usage ?? 0) / MB), quotaMB: round((est.quota ?? 0) / MB) } : null;
      await tx(db, 'blobs', 'readwrite', (st) => st.clear());
      db.close();
      out.indexedDB = results;
    } catch (e) {
      out.indexedDB = `error: ${(e as Error).message}`;
    }

    try {
      if (navigator.storage?.getDirectory) {
        const root = await navigator.storage.getDirectory();
        const fh = await root.getFileHandle('m0-probe.bin', { create: true });
        const writable = (fh as FileSystemFileHandle & { createWritable?: () => Promise<FileSystemWritableFileStream> }).createWritable;
        if (writable) {
          const t0 = performance.now();
          const w = await writable.call(fh);
          await w.write(new Uint8Array(32 * MB));
          await w.close();
          out.opfs = { available: true, createWritable: true, write32MBms: round(performance.now() - t0) };
        } else out.opfs = { available: true, createWritable: false, note: 'main-thread createWritable missing; sync access handles (workers) not probed here' };
        await root.removeEntry('m0-probe.bin');
      } else out.opfs = { available: false };
    } catch (e) {
      out.opfs = `error: ${(e as Error).message}`;
    }
    return out;
  },
};

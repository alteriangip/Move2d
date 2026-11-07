/**
 * Pixel-accurate layer picking. For each image a small alpha mask (≤128 px on
 * the long side) is built once from the stored image bytes; a tap selects the
 * topmost visible, unlocked layer whose mask is opaque at that point.
 */
import type { Doc, Id, LayerNode } from '../engine/model/types';
import { drawList } from '../engine/model/ops';
import type { Asset } from '../engine/model/types';

interface Mask {
  w: number;
  h: number;
  a: Uint8Array;
}

const masks = new Map<Id, Mask | 'loading'>();
const MAX = 128;

export function ensureMask(asset: Asset, onReady: () => void): void {
  if (masks.has(asset.id)) return;
  masks.set(asset.id, 'loading');
  createImageBitmap(new Blob([asset.bytes], { type: asset.mime }))
    .then((bmp) => {
      const s = Math.min(1, MAX / Math.max(bmp.width, bmp.height));
      const w = Math.max(1, Math.round(bmp.width * s)),
        h = Math.max(1, Math.round(bmp.height * s));
      const c = new OffscreenCanvas(w, h);
      const g = c.getContext('2d')!;
      g.drawImage(bmp, 0, 0, w, h);
      bmp.close();
      const d = g.getImageData(0, 0, w, h).data;
      const a = new Uint8Array(w * h);
      for (let i = 0; i < a.length; i++) a[i] = d[i * 4 + 3];
      masks.set(asset.id, { w, h, a });
      onReady();
    })
    .catch(() => masks.delete(asset.id));
}

function opaqueAt(l: LayerNode, x: number, y: number): boolean {
  const m = masks.get(l.imageId);
  if (!m || m === 'loading') return true; // until the mask is ready, fall back to the bounding box
  const u = Math.floor(((x - l.x) / l.width) * m.w);
  const v = Math.floor(((y - l.y) / l.height) * m.h);
  // accept a 1-cell neighbourhood so thin lines stay tappable
  for (let dy = -1; dy <= 1; dy++)
    for (let dx = -1; dx <= 1; dx++) {
      const uu = u + dx,
        vv = v + dy;
      if (uu >= 0 && vv >= 0 && uu < m.w && vv < m.h && m.a[vv * m.w + uu] > 24) return true;
    }
  return false;
}

/** Topmost selectable layer at document point (x, y), or null. */
export function pickLayer(doc: Doc, x: number, y: number): LayerNode | null {
  const list = drawList(doc);
  for (let i = list.length - 1; i >= 0; i--) {
    const l = list[i].layer;
    if (isLocked(doc, l.id)) continue;
    if (x < l.x || y < l.y || x >= l.x + l.width || y >= l.y + l.height) continue;
    if (opaqueAt(l, x, y)) return l;
  }
  return null;
}

/** A node is locked if it or any ancestor is locked. */
export function isLocked(doc: Doc, id: Id): boolean {
  let cur: Id | null = id;
  while (cur) {
    const n: Doc['nodes'][string] | undefined = doc.nodes[cur];
    if (!n) return false;
    if (n.locked) return true;
    cur = n.parentId;
  }
  return false;
}

/** All layers under the given nodes (groups expand to their descendants). */
export function layersUnder(doc: Doc, ids: Id[]): LayerNode[] {
  const out = new Map<Id, LayerNode>();
  const rec = (id: Id) => {
    const n = doc.nodes[id];
    if (!n) return;
    if (n.kind === 'layer') out.set(n.id, n);
    else n.childIds.forEach(rec);
  };
  ids.forEach(rec);
  return [...out.values()];
}

/** Bounding box (doc px) of the given nodes, or null if empty. */
export function boundsOf(doc: Doc, ids: Id[]): { x: number; y: number; w: number; h: number } | null {
  const ls = layersUnder(doc, ids);
  if (!ls.length) return null;
  let x0 = Infinity,
    y0 = Infinity,
    x1 = -Infinity,
    y1 = -Infinity;
  for (const l of ls) {
    x0 = Math.min(x0, l.x);
    y0 = Math.min(y0, l.y);
    x1 = Math.max(x1, l.x + l.width);
    y1 = Math.max(y1, l.y + l.height);
  }
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

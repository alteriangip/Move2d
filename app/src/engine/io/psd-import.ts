/**
 * Main-thread side of PSD import: drives the worker and converts the chosen
 * layers into document nodes + image assets.
 */
import PsdWorker from './psd.worker?worker&inline';
import type { Asset, Doc, GroupNode, Id, LayerNode, Node } from '../model/types';
import { newId } from '../model/ops';
import type { DecodedImage, FromWorker, ImportNode, PsdStructure } from './psd-types';

export class PsdImportSession {
  private worker = new PsdWorker();
  structure: PsdStructure | null = null;

  private request<T>(msg: unknown, transfer: Transferable[], until: (m: FromWorker) => T | undefined, onOther?: (m: FromWorker) => void): Promise<T> {
    return new Promise((resolve, reject) => {
      this.worker.onmessage = (e: MessageEvent<FromWorker>) => {
        const m = e.data;
        if (m.type === 'error') return reject(new Error(m.message));
        const r = until(m);
        if (r !== undefined) resolve(r);
        else onOther?.(m);
      };
      this.worker.onerror = (e) => reject(new Error(e.message || 'Import worker failed'));
      this.worker.postMessage(msg, transfer);
    });
  }

  /** Reads the layer tree (no pixel decoding). */
  async parse(buffer: ArrayBuffer): Promise<PsdStructure> {
    this.structure = await this.request({ type: 'parse', buffer }, [buffer], (m) => (m.type === 'structure' ? m.structure : undefined));
    return this.structure;
  }

  /** Decodes the selected layers; reports progress. */
  async decode(keys: string[], onProgress: (done: number, total: number, name: string) => void): Promise<{ images: Map<string, DecodedImage>; warnings: string[] }> {
    const images = new Map<string, DecodedImage>();
    const warnings = await this.request(
      { type: 'decode', keys },
      [],
      (m) => (m.type === 'decoded' ? m.warnings : undefined),
      (m) => {
        if (m.type === 'image') images.set(m.image.key, m.image);
        else if (m.type === 'progress') onProgress(m.done, m.total, m.name);
      },
    );
    return { images, warnings };
  }

  dispose() {
    this.worker.terminate();
  }
}

/** Keys of all importable pixel layers under the given nodes, honoring the exclusion set. */
export function selectedLayerKeys(tree: ImportNode[], excluded: Set<string>): string[] {
  const out: string[] = [];
  const rec = (ns: ImportNode[]) => {
    for (const n of ns) {
      if (excluded.has(n.key)) continue;
      if (n.children) rec(n.children);
      else if (!n.skipReason) out.push(n.key);
    }
  };
  rec(tree);
  return out;
}

/**
 * Builds document nodes for the imported tree. Returns the new nodes, the
 * top-level ids (in order) and the assets. Groups that end up empty are dropped.
 */
export function buildNodes(
  tree: ImportNode[],
  images: Map<string, DecodedImage>,
  excluded: Set<string>,
  parentId: Id | null,
): { nodes: Node[]; topIds: Id[]; assets: Asset[] } {
  const nodes: Node[] = [];
  const assets: Asset[] = [];
  const rec = (ns: ImportNode[], parent: Id | null): Id[] => {
    const ids: Id[] = [];
    for (const n of ns) {
      if (excluded.has(n.key)) continue;
      if (n.children) {
        const id = newId();
        const kids = rec(n.children, id);
        if (!kids.length) continue;
        const g: GroupNode = { id, kind: 'group', name: n.name, parentId: parent, visible: n.visible, locked: false, opacity: n.opacity, childIds: kids, expanded: false };
        nodes.push(g);
        ids.push(id);
      } else {
        const img = images.get(n.key);
        if (!img) continue;
        const id = newId();
        const imageId = newId();
        assets.push({ id: imageId, width: img.width, height: img.height, mime: 'image/png', bytes: img.png });
        const l: LayerNode = {
          id,
          kind: 'layer',
          name: n.name,
          parentId: parent,
          visible: n.visible,
          locked: false,
          opacity: n.opacity,
          imageId,
          x: n.left + img.left,
          y: n.top + img.top,
          width: img.width,
          height: img.height,
          blendMode: n.blendMode,
          clipping: n.clipping,
        };
        nodes.push(l);
        ids.push(id);
      }
    }
    return ids;
  };
  const topIds = rec(tree, parentId);
  return { nodes, topIds, assets };
}

/** Wraps a single bitmap file (PNG/JPEG) as one layer. */
export async function importImageFile(file: File, doc: Doc | null): Promise<{ node: LayerNode; asset: Asset; width: number; height: number }> {
  const bytes = await file.arrayBuffer();
  const bmp = await createImageBitmap(new Blob([bytes], { type: file.type }));
  const { width, height } = bmp;
  bmp.close();
  const imageId = newId();
  const mime = file.type === 'image/jpeg' ? 'image/jpeg' : 'image/png';
  const x = doc ? Math.round((doc.width - width) / 2) : 0;
  const y = doc ? Math.round((doc.height - height) / 2) : 0;
  return {
    node: {
      id: newId(),
      kind: 'layer',
      name: file.name.replace(/\.[^.]+$/, ''),
      parentId: null,
      visible: true,
      locked: false,
      opacity: 1,
      imageId,
      x,
      y,
      width,
      height,
      blendMode: 'normal',
      clipping: false,
    },
    asset: { id: imageId, width, height, mime, bytes },
    width,
    height,
  };
}

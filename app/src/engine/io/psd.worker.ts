/// <reference lib="webworker" />
/**
 * PSD import worker.
 *
 * Phase 1 ("parse"): reads the layer tree without decoding pixels (fast), so the
 * user can preview and choose layers.
 * Phase 2 ("decode"): decodes the chosen layers one at a time (ag-psd lazy
 * mode — M0 measured ~12× lower peak memory than decoding all at once), bakes
 * raster masks into alpha, crops to the visible pixels and encodes PNG. Each
 * image is transferred back as soon as it is ready and released here.
 */
import { initializeCanvas, readPsd, getLayerImageData, getLayerMaskImageData, type Layer, type Psd } from 'ag-psd';
import type { BlendMode } from '../model/types';
import type { FromWorker, ImportNode, PsdStructure, ToWorker } from './psd-types';

// ag-psd needs factories; without them it silently drops pixels in workers (found in M0).
initializeCanvas(
  (w, h) => new OffscreenCanvas(w, h) as unknown as HTMLCanvasElement,
  (w, h) => new ImageData(w, h),
);

const post = (m: FromWorker, transfer: Transferable[] = []) => (self as DedicatedWorkerGlobalScope).postMessage(m, transfer);

let psd: Psd | null = null;
const byKey = new Map<string, Layer>();

const BLEND: Record<string, BlendMode | undefined> = {
  normal: 'normal',
  'pass through': 'normal',
  multiply: 'multiply',
  'linear dodge': 'additive',
};

function toTree(layers: Layer[] | undefined, prefix: string, warnings: string[]): ImportNode[] {
  return (layers ?? []).map((l, i) => {
    const key = prefix ? `${prefix}/${i}` : String(i);
    byKey.set(key, l);
    const bm = l.blendMode ?? 'normal';
    const blendMode = BLEND[bm] ?? 'normal';
    if (!BLEND[bm]) warnings.push(`“${l.name}”: blend mode “${bm}” is not supported yet and was imported as Normal.`);
    const width = (l.right ?? 0) - (l.left ?? 0);
    const height = (l.bottom ?? 0) - (l.top ?? 0);
    const n: ImportNode = {
      key,
      name: l.name ?? 'Layer',
      kind: l.children ? 'group' : 'layer',
      visible: !l.hidden,
      opacity: (l.opacity ?? 1) * (l.fillOpacity ?? 1),
      blendMode,
      clipping: !!l.clipping,
      left: l.left ?? 0,
      top: l.top ?? 0,
      width,
      height,
    };
    if (l.children) n.children = toTree(l.children, key, warnings);
    else if (l.adjustment) n.skipReason = 'Adjustment layer (no pixels)';
    else if (width <= 0 || height <= 0) n.skipReason = 'Empty layer';
    if (l.effects && Object.keys(l.effects).length) warnings.push(`“${l.name}”: layer effects (shadows, strokes…) are not rendered.`);
    if (l.vectorMask) warnings.push(`“${l.name}”: vector mask ignored; rasterize it in your paint app if needed.`);
    return n;
  });
}

function to8bit(data: ArrayLike<number>, n: number): Uint8ClampedArray {
  if (data instanceof Uint8ClampedArray) return data;
  const out = new Uint8ClampedArray(n);
  if (data instanceof Uint16Array) for (let i = 0; i < n; i++) out[i] = data[i] >> 8;
  else for (let i = 0; i < n; i++) out[i] = Math.round((data[i] as number) * 255);
  return out;
}

async function decode(keys: string[]) {
  if (!psd) throw new Error('No PSD loaded');
  const warnings: string[] = [];
  let done = 0;
  for (const key of keys) {
    const l = byKey.get(key);
    if (!l || l.children) continue;
    post({ type: 'progress', done, total: keys.length, name: l.name ?? '' });
    const px = getLayerImageData(l);
    const w = px?.width ?? 0,
      h = px?.height ?? 0;
    if (!px || !w || !h) {
      warnings.push(`“${l.name}”: pixels could not be decoded; layer skipped.`);
      done++;
      continue;
    }
    const data = to8bit(px.data as ArrayLike<number>, w * h * 4);
    // Bake a raster layer mask into alpha.
    const m = l.mask && !l.mask.disabled ? getLayerMaskImageData(l) : undefined;
    if (l.mask && !l.mask.disabled) {
      const ml = l.mask.left ?? 0,
        mt = l.mask.top ?? 0,
        def = l.mask.defaultColor ?? 255;
      const mw = m?.width ?? 0,
        mh = m?.height ?? 0;
      const md = m ? (m.data as ArrayLike<number>) : null;
      const lx = l.left ?? 0,
        ly = l.top ?? 0;
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++) {
          const mx = x + lx - ml,
            my = y + ly - mt;
          const mv = md && mx >= 0 && my >= 0 && mx < mw && my < mh ? (md[(my * mw + mx) * 4] as number) : def;
          const o = (y * w + x) * 4 + 3;
          data[o] = (data[o] * mv) / 255;
        }
    }
    // Crop to non-transparent pixels.
    let x0 = w,
      y0 = h,
      x1 = -1,
      y1 = -1;
    for (let y = 0; y < h; y++) {
      const row = y * w * 4;
      for (let x = 0; x < w; x++)
        if (data[row + x * 4 + 3] !== 0) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
    }
    if (x1 < 0) {
      warnings.push(`“${l.name}”: layer is fully transparent; skipped.`);
      done++;
      continue;
    }
    const cw = x1 - x0 + 1,
      ch = y1 - y0 + 1;
    const canvas = new OffscreenCanvas(cw, ch);
    const g = canvas.getContext('2d')!;
    g.putImageData(new ImageData(data as Uint8ClampedArray<ArrayBuffer>, w, h), -x0, -y0);
    const blob = await canvas.convertToBlob({ type: 'image/png' });
    const png = await blob.arrayBuffer();
    post({ type: 'image', image: { key, left: x0, top: y0, width: cw, height: ch, png } }, [png]);
    done++;
  }
  post({ type: 'decoded', warnings });
}

self.onmessage = async (e: MessageEvent<ToWorker>) => {
  try {
    const msg = e.data;
    if (msg.type === 'parse') {
      byKey.clear();
      psd = readPsd(msg.buffer, { useRawData: true, skipCompositeImageData: true, skipThumbnail: true });
      const warnings: string[] = [];
      if (psd.colorMode !== 3) warnings.push(`Color mode ${psd.colorMode} is not RGB; colors may be wrong. Convert to RGB in your paint app for best results.`);
      if ((psd.bitsPerChannel ?? 8) > 8) warnings.push(`${psd.bitsPerChannel}-bit channels are converted to 8-bit.`);
      const tree = toTree(psd.children, '', warnings);
      let layerCount = 0;
      const count = (ns: ImportNode[]) => ns.forEach((n) => (n.children ? count(n.children) : layerCount++));
      count(tree);
      const structure: PsdStructure = {
        width: psd.width,
        height: psd.height,
        bitsPerChannel: psd.bitsPerChannel ?? 8,
        colorMode: psd.colorMode ?? 3,
        tree,
        layerCount,
        warnings: [...new Set(warnings)],
      };
      post({ type: 'structure', structure });
    } else if (msg.type === 'decode') {
      await decode(msg.keys);
    } else if (msg.type === 'dispose') {
      psd = null;
      byKey.clear();
    }
  } catch (err) {
    post({ type: 'error', message: (err as Error).message || String(err) });
  }
};

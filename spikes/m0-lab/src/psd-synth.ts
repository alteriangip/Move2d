/**
 * Synthetic layered PSD generator for reproducible import benchmarks.
 *
 * Generates artist-like layers (flat-colour blobs with anti-aliased edges and
 * line-art strokes), each with its own bounds, in nested groups, with varied
 * opacity, visibility, blend modes and clipping. Uses ag-psd's writer with raw
 * ImageData so it runs in browsers and in Node (tests).
 */
import { writePsd, type Psd, type Layer, type BlendMode } from 'ag-psd';
import { rng } from './rig-kernel';

export interface SynthSpec {
  name: string;
  width: number;
  height: number;
  layers: number;
  /** layer bounds as a fraction of the document size: [min, max]. */
  sizeFrac: [number, number];
  seed: number;
}

export const PSD_PRESETS: SynthSpec[] = [
  { name: 'small', width: 2000, height: 3000, layers: 40, sizeFrac: [0.05, 0.3], seed: 11 },
  { name: 'medium', width: 3000, height: 4500, layers: 100, sizeFrac: [0.05, 0.25], seed: 12 },
  { name: 'large', width: 4000, height: 6000, layers: 150, sizeFrac: [0.05, 0.25], seed: 13 },
];

/** Expected metadata per pixel layer, top-to-bottom document order. */
export interface ExpectedLayer {
  path: string; // "Group/Sub/Layer"
  left: number;
  top: number;
  width: number;
  height: number;
  opacity: number; // 0..1
  hidden: boolean;
  blendMode: BlendMode;
  clipping: boolean;
}

export interface SynthResult {
  buffer: ArrayBuffer;
  expected: ExpectedLayer[];
  groups: number;
  /** total raw RGBA bytes of all layer images. */
  rawLayerBytes: number;
  genMs: number;
  writeMs: number;
}

const BLENDS: BlendMode[] = ['normal', 'normal', 'normal', 'normal', 'multiply', 'linear dodge', 'screen'];

/** Creates a plain ImageData-shaped object (no DOM dependency). */
function makeImageData(w: number, h: number): { width: number; height: number; data: Uint8ClampedArray } {
  return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) };
}

function paintLayer(
  img: { width: number; height: number; data: Uint8ClampedArray },
  r: () => number,
): void {
  const { width: w, height: h, data } = img;
  const cr = Math.floor(r() * 255),
    cg = Math.floor(r() * 255),
    cb = Math.floor(r() * 255);
  const cx = w / 2,
    cy = h / 2,
    rx = w / 2 - 2,
    ry = h / 2 - 2;
  // Soft-edged ellipse (anti-aliased over ~1.5px) + a darker line-art ring.
  for (let y = 0; y < h; y++) {
    const dy = (y + 0.5 - cy) / ry;
    for (let x = 0; x < w; x++) {
      const dx = (x + 0.5 - cx) / rx;
      const d = Math.sqrt(dx * dx + dy * dy);
      const edgePx = (1 - d) * Math.min(rx, ry);
      let a = edgePx > 1.5 ? 1 : edgePx <= 0 ? 0 : edgePx / 1.5;
      if (a === 0) continue;
      const o = (y * w + x) * 4;
      const ring = edgePx < 6 ? 0.45 : 1; // line art
      const shade = 0.85 + 0.15 * (1 - y / h); // simple vertical shading
      data[o] = cr * ring * shade;
      data[o + 1] = cg * ring * shade;
      data[o + 2] = cb * ring * shade;
      data[o + 3] = a * 255;
    }
  }
}

/** Generates a synthetic PSD as an ArrayBuffer plus the metadata it should yield. */
export function generatePsd(spec: SynthSpec): SynthResult {
  const r = rng(spec.seed);
  const t0 = performance.now();
  const root: Layer[] = [];
  const expected: ExpectedLayer[] = [];
  let groups = 0;
  let raw = 0;

  // Build top-level groups (like "Head", "Body"...), each with sub-groups.
  const topCount = Math.max(2, Math.round(spec.layers / 25));
  const perTop = Math.ceil(spec.layers / topCount);
  let made = 0;
  for (let gi = 0; gi < topCount && made < spec.layers; gi++) {
    const gName = `Group ${gi + 1}`;
    const top: Layer = { name: gName, opened: true, children: [], opacity: gi === 1 ? 0.8 : 1 };
    groups++;
    const subCount = 2;
    for (let si = 0; si < subCount && made < spec.layers; si++) {
      const sName = `Sub ${gi + 1}.${si + 1}`;
      const sub: Layer = { name: sName, opened: true, children: [] };
      groups++;
      const n = Math.ceil(perTop / subCount);
      for (let li = 0; li < n && made < spec.layers; li++) {
        const fw = spec.sizeFrac[0] + r() * (spec.sizeFrac[1] - spec.sizeFrac[0]);
        const fh = spec.sizeFrac[0] + r() * (spec.sizeFrac[1] - spec.sizeFrac[0]);
        const w = Math.max(8, Math.round(spec.width * fw));
        const h = Math.max(8, Math.round(spec.height * fh));
        const left = Math.floor(r() * (spec.width - w));
        const top_ = Math.floor(r() * (spec.height - h));
        const img = makeImageData(w, h);
        paintLayer(img, r);
        raw += w * h * 4;
        const opacity = r() < 0.2 ? Math.round((0.4 + r() * 0.5) * 255) / 255 : 1;
        const hidden = r() < 0.08;
        const blendMode = BLENDS[Math.floor(r() * BLENDS.length)];
        const clipping = li > 0 && r() < 0.1;
        const name = `Layer ${made + 1} ✎`; // non-ASCII on purpose (Unicode names)
        sub.children!.push({
          name,
          left,
          top: top_,
          right: left + w,
          bottom: top_ + h,
          opacity,
          hidden,
          blendMode,
          clipping,
          imageData: img as unknown as ImageData,
        });
        made++;
      }
      top.children!.push(sub);
    }
    root.push(top);
  }
  const genMs = performance.now() - t0;

  // ag-psd children are ordered top-to-bottom, as shown in Photoshop.
  const walk = (layers: Layer[], prefix: string) => {
    for (let i = 0; i < layers.length; i++) {
      const l = layers[i];
      const path = prefix ? `${prefix}/${l.name}` : l.name!;
      if (l.children) walk(l.children, path);
      else
        expected.push({
          path,
          left: l.left!,
          top: l.top!,
          width: l.right! - l.left!,
          height: l.bottom! - l.top!,
          opacity: l.opacity ?? 1,
          hidden: !!l.hidden,
          blendMode: l.blendMode ?? 'normal',
          clipping: !!l.clipping,
        });
    }
  };
  walk(root, '');

  const psd: Psd = { width: spec.width, height: spec.height, channels: 3, bitsPerChannel: 8, colorMode: 3, children: root };
  const t1 = performance.now();
  const buffer = writePsd(psd, { generateThumbnail: false, noBackground: true, trimImageData: false });
  const writeMs = performance.now() - t1;
  // Release layer pixels before returning so callers measure parsing alone.
  const strip = (layers: Layer[]) => layers.forEach((l) => (l.children ? strip(l.children) : (l.imageData = undefined)));
  strip(root);
  return { buffer, expected, groups, rawLayerBytes: raw, genMs, writeMs };
}

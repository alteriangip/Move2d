/**
 * PSD import benchmark: compares parsing strategies on the same buffer and
 * verifies metadata fidelity against the generator's expectations.
 *
 * Safari exposes no JS heap measurement API, so memory is reported as an
 * *accounted* estimate: file buffer + the largest amount of decoded pixel
 * data simultaneously held by the strategy. Real-process limits are probed
 * separately by the crash-threshold stress tests.
 */
import './ag-init';
import { readPsd, getLayerImageData, type Layer as AgLayer, type Psd as AgPsd } from 'ag-psd';
import PsdWebtoon from '@webtoon/psd';
import type { ExpectedLayer } from './psd-synth';

export interface ParsedLayerMeta {
  path: string;
  left: number;
  top: number;
  width: number;
  height: number;
  opacity: number;
  hidden: boolean;
  blendMode?: string;
  clipping?: boolean;
}

export interface StrategyResult {
  strategy: string;
  ok: boolean;
  error?: string;
  parseMs: number;
  decodeMs: number;
  totalMs: number;
  layers: number;
  decodedBytes: number;
  /** file bytes + peak simultaneously-held decoded bytes. */
  accountedPeakBytes: number;
  fidelity?: Fidelity;
}

export interface Fidelity {
  compared: number;
  mismatches: number;
  fields: Record<string, number>;
  firstMismatch?: string;
}

/** Flattens an ag-psd tree into pixel-layer metadata, top-to-bottom. */
export function flattenAg(psd: AgPsd): ParsedLayerMeta[] {
  const out: ParsedLayerMeta[] = [];
  const walk = (layers: AgLayer[] | undefined, prefix: string) => {
    for (const l of layers ?? []) {
      const path = prefix ? `${prefix}/${l.name}` : (l.name ?? '');
      if (l.children) walk(l.children, path);
      else
        out.push({
          path,
          left: l.left ?? 0,
          top: l.top ?? 0,
          width: (l.right ?? 0) - (l.left ?? 0),
          height: (l.bottom ?? 0) - (l.top ?? 0),
          opacity: l.opacity ?? 1,
          hidden: !!l.hidden,
          blendMode: l.blendMode,
          clipping: !!l.clipping,
        });
    }
  };
  walk(psd.children, '');
  return out;
}

type WNode = { type: string; name: string; children?: WNode[] } & Record<string, unknown>;

/** Flattens a @webtoon/psd tree into pixel-layer metadata, top-to-bottom. */
export function flattenWebtoon(psd: { children: WNode[] }): { meta: ParsedLayerMeta[]; layers: WNode[] } {
  const meta: ParsedLayerMeta[] = [];
  const layers: WNode[] = [];
  // @webtoon/psd lists children bottom-to-top; normalize to top-to-bottom.
  const walk = (nodes: WNode[], prefix: string) => {
    for (let i = nodes.length - 1; i >= 0; i--) {
      const n = nodes[i];
      const path = prefix ? `${prefix}/${n.name}` : n.name;
      if (n.type === 'Group') walk(n.children ?? [], path);
      else if (n.type === 'Layer') {
        const op = n.opacity as number;
        meta.push({
          path,
          left: n.left as number,
          top: n.top as number,
          width: n.width as number,
          height: n.height as number,
          opacity: op > 1 ? op / 255 : op,
          hidden: !!n.isHidden,
        });
        layers.push(n);
      }
    }
  };
  walk(psd.children, '');
  return { meta, layers };
}

/** Compares parsed metadata against expectations field by field. */
export function compareMeta(expected: ExpectedLayer[], got: ParsedLayerMeta[], fields: (keyof ParsedLayerMeta)[]): Fidelity {
  const f: Fidelity = { compared: Math.min(expected.length, got.length), mismatches: 0, fields: {} };
  if (expected.length !== got.length) {
    f.mismatches++;
    f.fields.count = 1;
    f.firstMismatch = `layer count expected ${expected.length} got ${got.length}`;
  }
  for (let i = 0; i < f.compared; i++) {
    for (const k of fields) {
      const e = expected[i][k as keyof ExpectedLayer];
      const g = got[i][k];
      const same = typeof e === 'number' && typeof g === 'number' ? Math.abs(e - g) < 1 / 255 + 1e-6 : e === g;
      if (!same) {
        f.mismatches++;
        f.fields[k] = (f.fields[k] ?? 0) + 1;
        f.firstMismatch ??= `#${i} ${String(k)}: expected ${JSON.stringify(e)} got ${JSON.stringify(g)}`;
      }
    }
  }
  return f;
}

const now = () => performance.now();
const AG_FIELDS: (keyof ParsedLayerMeta)[] = ['path', 'left', 'top', 'width', 'height', 'opacity', 'hidden', 'blendMode', 'clipping'];
const WT_FIELDS: (keyof ParsedLayerMeta)[] = ['path', 'left', 'top', 'width', 'height', 'opacity', 'hidden'];

function fail(strategy: string, e: unknown, t0: number): StrategyResult {
  return {
    strategy,
    ok: false,
    error: String((e as Error)?.message ?? e),
    parseMs: 0,
    decodeMs: 0,
    totalMs: now() - t0,
    layers: 0,
    decodedBytes: 0,
    accountedPeakBytes: 0,
  };
}

/** Yields to the event loop so the UI can repaint between heavy steps. */
export const tick = () => new Promise<void>((r) => setTimeout(r, 0));

/** ag-psd, structure only (no pixel decode). */
export function agStructure(buf: ArrayBuffer, expected?: ExpectedLayer[]): StrategyResult {
  const t0 = now();
  try {
    const psd = readPsd(buf, { skipLayerImageData: true, skipCompositeImageData: true, skipThumbnail: true });
    const t1 = now();
    const meta = flattenAg(psd);
    return {
      strategy: 'ag-psd structure only',
      ok: true,
      parseMs: t1 - t0,
      decodeMs: 0,
      totalMs: t1 - t0,
      layers: meta.length,
      decodedBytes: 0,
      accountedPeakBytes: buf.byteLength,
      fidelity: expected ? compareMeta(expected, meta, AG_FIELDS) : undefined,
    };
  } catch (e) {
    return fail('ag-psd structure only', e, t0);
  }
}

/** ag-psd eager: decodes every layer into ImageData in one call. */
export function agEager(buf: ArrayBuffer, expected?: ExpectedLayer[]): StrategyResult {
  const t0 = now();
  try {
    const psd = readPsd(buf, { useImageData: true, skipCompositeImageData: true, skipThumbnail: true, throwForMissingFeatures: false, logMissingFeatures: false });
    const t1 = now();
    let bytes = 0;
    let missing = 0;
    const walk = (ls?: AgLayer[]) =>
      ls?.forEach((l) => {
        if (l.children) return walk(l.children);
        const hasArea = (l.right ?? 0) > (l.left ?? 0) && (l.bottom ?? 0) > (l.top ?? 0);
        if (!l.imageData && hasArea) missing++; // ag-psd silently drops layers it fails to decode
        bytes += l.imageData?.data.byteLength ?? 0;
      });
    walk(psd.children);
    if (missing) throw new Error(`${missing} layer(s) decoded to no pixels (silently dropped by ag-psd)`);
    const meta = flattenAg(psd);
    return {
      strategy: 'ag-psd eager (all layers at once)',
      ok: true,
      parseMs: t1 - t0,
      decodeMs: 0,
      totalMs: t1 - t0,
      layers: meta.length,
      decodedBytes: bytes,
      accountedPeakBytes: buf.byteLength + bytes,
      fidelity: expected ? compareMeta(expected, meta, AG_FIELDS) : undefined,
    };
  } catch (e) {
    return fail('ag-psd eager (all layers at once)', e, t0);
  }
}

/** ag-psd lazy: raw parse, then decode one layer at a time with getLayerImageData. */
export async function agLazy(buf: ArrayBuffer, expected?: ExpectedLayer[], onLayer?: (px: { data: ArrayLike<number>; width: number; height: number }) => void): Promise<StrategyResult> {
  const t0 = now();
  try {
    const psd = readPsd(buf, { useRawData: true, skipCompositeImageData: true, skipThumbnail: true });
    const t1 = now();
    let bytes = 0,
      peak = 0,
      n = 0;
    const layers: AgLayer[] = [];
    const walk = (ls?: AgLayer[]) => ls?.forEach((l) => (l.children ? walk(l.children) : layers.push(l)));
    walk(psd.children);
    for (const l of layers) {
      const px = getLayerImageData(l);
      if (px) {
        bytes += px.data.byteLength;
        peak = Math.max(peak, px.data.byteLength);
        onLayer?.(px);
      }
      if (++n % 10 === 0) await tick();
    }
    const t2 = now();
    const meta = flattenAg(psd);
    return {
      strategy: 'ag-psd lazy (one layer at a time)',
      ok: true,
      parseMs: t1 - t0,
      decodeMs: t2 - t1,
      totalMs: t2 - t0,
      layers: meta.length,
      decodedBytes: bytes,
      accountedPeakBytes: buf.byteLength * 2 + peak, // raw channel data is retained alongside the file
      fidelity: expected ? compareMeta(expected, meta, AG_FIELDS) : undefined,
    };
  } catch (e) {
    return fail('ag-psd lazy (one layer at a time)', e, t0);
  }
}

/** @webtoon/psd: structure parse then per-layer composite() (WASM decoder). */
export async function webtoon(buf: ArrayBuffer, expected?: ExpectedLayer[]): Promise<StrategyResult> {
  const t0 = now();
  try {
    const psd = PsdWebtoon.parse(buf) as unknown as { children: WNode[] };
    const t1 = now();
    const { meta, layers } = flattenWebtoon(psd);
    let bytes = 0,
      peak = 0,
      n = 0;
    for (const l of layers) {
      const px = await (l as unknown as { composite(e?: boolean, c?: boolean): Promise<Uint8ClampedArray> }).composite(false, false);
      bytes += px.byteLength;
      peak = Math.max(peak, px.byteLength);
      if (++n % 10 === 0) await tick();
    }
    const t2 = now();
    return {
      strategy: '@webtoon/psd (lazy, WASM)',
      ok: true,
      parseMs: t1 - t0,
      decodeMs: t2 - t1,
      totalMs: t2 - t0,
      layers: meta.length,
      decodedBytes: bytes,
      accountedPeakBytes: buf.byteLength + peak,
      fidelity: expected ? compareMeta(expected, meta, WT_FIELDS) : undefined,
    };
  } catch (e) {
    return fail('@webtoon/psd (lazy, WASM)', e, t0);
  }
}

/** Feature census of a user-supplied PSD: counts only, no names or pixels leave the device. */
export function census(buf: ArrayBuffer): Record<string, unknown> {
  const psd = readPsd(buf, { skipLayerImageData: true, skipCompositeImageData: true, skipThumbnail: true });
  const c = {
    width: psd.width,
    height: psd.height,
    colorMode: psd.colorMode,
    bitsPerChannel: psd.bitsPerChannel,
    fileBytes: buf.byteLength,
    pixelLayers: 0,
    groups: 0,
    maxDepth: 0,
    hidden: 0,
    clipped: 0,
    rasterMasks: 0,
    vectorMasks: 0,
    text: 0,
    smartObjects: 0,
    adjustment: 0,
    withEffects: 0,
    blendModes: {} as Record<string, number>,
    largestLayerPx: 0,
    totalLayerPx: 0,
  };
  const walk = (ls: AgLayer[] | undefined, d: number) => {
    for (const l of ls ?? []) {
      c.maxDepth = Math.max(c.maxDepth, d);
      if (l.children) {
        c.groups++;
        walk(l.children, d + 1);
        continue;
      }
      c.pixelLayers++;
      if (l.hidden) c.hidden++;
      if (l.clipping) c.clipped++;
      if (l.mask) c.rasterMasks++;
      if (l.vectorMask) c.vectorMasks++;
      if (l.text) c.text++;
      if (l.placedLayer) c.smartObjects++;
      if (l.adjustment) c.adjustment++;
      if (l.effects && Object.keys(l.effects).length) c.withEffects++;
      const bm = l.blendMode ?? 'normal';
      c.blendModes[bm] = (c.blendModes[bm] ?? 0) + 1;
      const px = ((l.right ?? 0) - (l.left ?? 0)) * ((l.bottom ?? 0) - (l.top ?? 0));
      c.largestLayerPx = Math.max(c.largestLayerPx, px);
      c.totalLayerPx += px;
    }
  };
  walk(psd.children, 1);
  return c;
}

/**
 * PSD import experiment UI: synthetic presets (reproducible on every device)
 * and an optional user-chosen PSD (only counts/timings are recorded — no
 * layer names or pixels leave the device).
 */
import './ag-init';
import { readPsd, getLayerImageData, type Layer as AgLayer } from 'ag-psd';
import type { Ctx, Experiment } from './experiment';
import { round, sleep, MB } from './experiment';
import { generatePsd, PSD_PRESETS } from './psd-synth';
import { agStructure, agEager, agLazy, webtoon, census, type StrategyResult } from './psd-bench';
import { summarize } from './stats';

/** Import-pipeline cost: decode one layer at a time, crop to alpha bounds, PNG-encode. */
async function pipeline(buf: ArrayBuffer, maxLayers = 40): Promise<Record<string, unknown>> {
  const t0 = performance.now();
  const psd = readPsd(buf, { useRawData: true, skipCompositeImageData: true, skipThumbnail: true });
  const layers: AgLayer[] = [];
  const walk = (ls?: AgLayer[]) => ls?.forEach((l) => (l.children ? walk(l.children) : layers.push(l)));
  walk(psd.children);
  const enc: number[] = [];
  const perMP: number[] = [];
  let pngBytes = 0,
    rawBytes = 0,
    cropSaved = 0,
    n = 0;
  for (const l of layers.slice(0, maxLayers)) {
    const px = getLayerImageData(l);
    if (!px || !px.width || !px.height) continue;
    const t1 = performance.now();
    // crop to alpha bounds
    const d = px.data as Uint8ClampedArray;
    let x0 = px.width,
      y0 = px.height,
      x1 = -1,
      y1 = -1;
    for (let y = 0; y < px.height; y++)
      for (let x = 0; x < px.width; x++)
        if (d[(y * px.width + x) * 4 + 3] > 0) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
    if (x1 < 0) continue;
    const w = x1 - x0 + 1,
      h = y1 - y0 + 1;
    cropSaved += px.width * px.height - w * h;
    const img = new ImageData(new Uint8ClampedArray(d.buffer as ArrayBuffer, d.byteOffset, d.byteLength), px.width, px.height);
    let blob: Blob;
    if (typeof OffscreenCanvas !== 'undefined') {
      const oc = new OffscreenCanvas(w, h);
      oc.getContext('2d')!.putImageData(img, -x0, -y0);
      blob = await oc.convertToBlob({ type: 'image/png' });
    } else {
      const c = document.createElement('canvas');
      c.width = w;
      c.height = h;
      c.getContext('2d')!.putImageData(img, -x0, -y0);
      blob = await new Promise<Blob>((r) => c.toBlob((b) => r(b!), 'image/png'));
      c.width = c.height = 0;
    }
    const ms = performance.now() - t1;
    enc.push(ms);
    perMP.push(ms / ((w * h) / 1e6));
    pngBytes += blob.size;
    rawBytes += w * h * 4;
    n++;
    if (n % 5 === 0) await sleep(0);
  }
  return {
    layersProcessed: n,
    cropEncodeMsPerLayer: summarize(enc),
    cropEncodeMsPerMegapixel: summarize(perMP),
    pngToRawRatio: rawBytes ? round(pngBytes / rawBytes, 3) : null,
    pixelsSavedByCropPct: rawBytes ? round((100 * cropSaved) / (cropSaved + rawBytes / 4), 1) : null,
    totalMs: round(performance.now() - t0),
  };
}

function compact(r: StrategyResult) {
  return {
    ...r,
    parseMs: round(r.parseMs),
    decodeMs: round(r.decodeMs),
    totalMs: round(r.totalMs),
    decodedMB: round(r.decodedBytes / MB),
    accountedPeakMB: round(r.accountedPeakBytes / MB),
  };
}

async function runStrategies(ctx: Ctx, key: string, buf: ArrayBuffer, expected: Parameters<typeof agEager>[1], out: Record<string, unknown>) {
  const res: Record<string, unknown> = {};
  out[key] = res;
  const strategies: [string, () => Promise<StrategyResult> | StrategyResult][] = [
    ['agStructure', () => agStructure(buf, expected)],
    ['agLazy', () => agLazy(buf, expected)],
    ['webtoon', () => webtoon(buf, expected)],
    ['agEager', () => agEager(buf, expected)], // highest peak memory: run last
  ];
  for (const [name, f] of strategies) {
    ctx.crumb(0, { psd: key, strategy: name, fileMB: round(buf.byteLength / MB) });
    ctx.log(`${key}: ${name}…`);
    await sleep(30);
    res[name] = compact(await f());
    ctx.partial(out);
  }
  ctx.crumb(0, { psd: key, strategy: 'pipeline' });
  ctx.log(`${key}: crop + PNG encode pipeline…`);
  res.pipeline = await pipeline(buf);
  ctx.partial(out);
}

export const psdBench: Experiment = {
  id: 'psd-import',
  title: 'PSD import (ag-psd vs @webtoon/psd)',
  summary: 'Generates layered PSDs (40/100/150 layers, up to 4000×6000) and compares parse strategies; optional: your own PSD.',
  interactive: true,
  risky: true,
  run(ctx: Ctx) {
    return new Promise((resolve) => {
      const out: Record<string, unknown> = {};
      ctx.panel.innerHTML = '';
      const p = document.createElement('p');
      p.textContent =
        'Run the synthetic presets (same files on every device). Optionally add one of your own PSDs: only counts and timings are recorded, never names or pixels.';
      const run = document.createElement('button');
      run.className = 'primary';
      run.textContent = 'Run synthetic presets (small → large)';
      const pick = document.createElement('input');
      pick.type = 'file';
      pick.accept = '.psd,.psb,image/vnd.adobe.photoshop';
      const pickLabel = document.createElement('label');
      pickLabel.className = 'file';
      pickLabel.append('Add my own PSD… ', pick);
      const finish = document.createElement('button');
      finish.textContent = 'Finish';
      ctx.panel.append(p, run, pickLabel, finish);
      const busy = (b: boolean) => [run, pick, finish].forEach((x) => ((x as HTMLButtonElement).disabled = b));

      run.onclick = async () => {
        busy(true);
        for (const spec of PSD_PRESETS) {
          ctx.crumb(0, { psd: spec.name, strategy: 'generate', spec });
          ctx.log(`generating ${spec.name} PSD (${spec.layers} layers, ${spec.width}×${spec.height})…`);
          await sleep(30);
          let g: ReturnType<typeof generatePsd> | null = generatePsd(spec);
          const meta = {
            spec,
            fileMB: round(g.buffer.byteLength / MB),
            rawLayerMB: round(g.rawLayerBytes / MB),
            groups: g.groups,
            generateMs: round(g.genMs),
            writeMs: round(g.writeMs),
          };
          out[`${spec.name}.generated`] = meta;
          const { buffer, expected } = g;
          g = null;
          await sleep(100);
          await runStrategies(ctx, spec.name, buffer, expected, out);
        }
        busy(false);
        run.textContent = 'Synthetic presets done ✓';
      };
      pick.onchange = async () => {
        const f = pick.files?.[0];
        if (!f) return;
        busy(true);
        ctx.crumb(0, { psd: 'user', strategy: 'read', fileMB: round(f.size / MB) });
        const buf = await f.arrayBuffer();
        try {
          out['user.census'] = census(buf);
        } catch (e) {
          out['user.census'] = { error: String(e) };
        }
        await runStrategies(ctx, 'user', buf, undefined, out);
        busy(false);
      };
      finish.onclick = () => resolve(out);
    });
  },
};

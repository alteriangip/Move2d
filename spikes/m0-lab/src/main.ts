/**
 * OpenLive M0 Platform Lab — shell UI.
 *
 * Runs each measurement experiment, keeps a crash-safe report, and lets the
 * tester submit it (to the artifact database when hosted on claude.ai) or
 * copy / download / share it as JSON.
 */
import './style.css';
import type { Experiment, Ctx } from './experiment';
import { makeCrumb, clearBreadcrumb, el } from './experiment';
import { loadReport, freshReport, saveReport, setResult, recoverCrash, reportJson, type Report } from './report';
import { collectEnv } from './env';
import { webglCaps, contextLoss, texturePipeline } from './exp-webgl';
import { rigBench } from './exp-rig';
import { pointerLab } from './exp-pointer';
import { navLab } from './exp-nav';
import { psdBench } from './exp-psd';
import { storageLab } from './exp-storage';
import { codecLab } from './exp-codec';
import { gpuStress, heapStress } from './exp-stress';

const AUTOMATIC: Experiment[] = [webglCaps, contextLoss, texturePipeline, storageLab, codecLab, rigBench];
const INTERACTIVE: Experiment[] = [navLab, pointerLab, psdBench];
const RISKY: Experiment[] = [gpuStress, heapStress];
const ALL = [...AUTOMATIC, ...INTERACTIVE, ...RISKY];

let report: Report = loadReport();
const recovered = recoverCrash(report);
let running = false;

/* ---------- headline numbers per experiment (what a screenshot should show) ---------- */

type D = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

function headline(id: string, d: D): string[] {
  try {
    switch (id) {
      case 'webgl-caps':
        return [
          `GPU: ${d.unmaskedRenderer ?? d.renderer}`,
          `MAX_TEXTURE_SIZE ${d.limits.MAX_TEXTURE_SIZE} · MSAA ${d.limits.MAX_SAMPLES}× · ASTC ${d.compressed.astc ? 'yes' : 'no'}`,
          `Transform feedback: ${d.transformFeedback.works ? 'works' : 'FAILED'} (${d.transformFeedback.roundTripMsIncludingReadback} ms / 100k verts)`,
        ];
      case 'webgl-context-loss':
        return [`Restore: ${d.restoreLatencyMs ?? '–'} ms · usable after: ${d.contextUsableAfterRestore} · 2048² rebuild ${d.rebuild2048TextureMs} ms`];
      case 'texture-pipeline':
        return ['s2048', 's4096'].filter((k) => d[k]).map((k) => {
          const s = d[k];
          return `${k.slice(1)}²: PNG enc ${s.pngEncodeCanvasMs} ms · decode ${s.decodeCreateImageBitmapMs} ms · upload ${s.uploadFromImageBitmapMs} ms`;
        });
      case 'storage':
        return [
          `Quota ${d.estimateBefore?.quotaMB ?? '?'} MB · persist() → ${d.persistRequestResult} · persisted ${d.persistedAfter}`,
          typeof d.indexedDB === 'object' ? `IndexedDB write ${d.indexedDB.writeMBps} MB/s · read ${d.indexedDB.readMBps} MB/s` : `IndexedDB: ${d.indexedDB}`,
          `Marker: visit #${d.evictionMarker?.visits}, first seen ${d.evictionMarker?.daysSinceFirstSeen} days ago`,
        ];
      case 'video-export': {
        const sup = d.encoderSupport ? Object.entries(d.encoderSupport).filter(([, v]) => v === true).map(([k]) => k) : [];
        return [
          `Encoders: ${sup.length ? sup.join(', ') : String(d.webCodecs ?? 'none')}`,
          d.encode1080p ? `1080p encode: ${d.encode1080p.encodeFps} fps (${d.encode1080p.config})` : '',
        ].filter(Boolean);
      }
      case 'rig-bench': {
        const lines = (d.passes as D[]).map(
          (p) =>
            `${p.preset} ${p.mode} @${p.renderScale}: ${p.fps} fps · ${p.vertices.toLocaleString()} v` +
            (p.evalMs ? ` · eval p95 ${p.evalMs.p95} ms` : '') +
            ` · submit p95 ${p.submitMs.p95} ms`,
        );
        if (d.decision)
          lines.push(
            `→ CPU eval reaches 4 ms (p95) at ≈ ${d.decision.verticesAt4msEvalP95?.toLocaleString() ?? '?'} vertices · GPU deformation needed for target model: ${d.decision.gpuDeformationNeededForTargetModel}`,
          );
        return lines;
      }
      case 'pointer-lab':
        return Object.entries(d.byType as D).map(
          ([t, s]: [string, D]) =>
            `${t}: ${s.eventRateHzMedian ?? '–'} Hz · pressure ${s.pressureLooksReal ? 'real' : 'none'} (${s.pressureDistinctLevels} lv) · tilt ${s.tiltLooksReal ? 'yes' : 'no'} · coalesced/move ${s.coalescedPerMoveAvg} · cancels ${s.cancels}`,
        ).concat([`Page zoom leaked: ${d.pageZoomLeak.leaked} · palm contacts during pen: ${d.touchContactsWhilePenDown} · contextmenu: ${d.contextmenuEvents}`]);
      case 'canvas-navigation':
        return [
          `Rating: ${d.rating ?? 'not rated'} · gesture frames p95 ${d.gestureFrameMs?.p95} ms (${d.gestureFramesOver20ms} over 20 ms) · event→frame p95 ${d.eventToNextFrameMs?.p95} ms`,
          `Pinch sessions ${d.pinchSessions} · pans ${d.panSessions} · zoom ${d.zoomRange?.join('–')}× · rotation up to ${d.maxRotationDeg}° · Pencil strokes ${d.penStrokes}`,
          `Palms ignored ${d.palmRejection?.palmsIgnored} (max contact ${d.palmRejection?.maxContactWidth} px) · cancels ${d.cancels?.count} · page zoom leaked: ${d.pageZoomLeak?.leaked}`,
        ];
      case 'psd-import':
        return Object.entries(d)
          .filter(([k]) => !k.includes('.'))
          .map(([k, v]: [string, D]) => {
            const f = (s: D) => (s?.ok ? `${Math.round(s.totalMs)} ms/${Math.round(s.accountedPeakMB)} MB` : `FAIL`);
            return `${k}: lazy ${f(v.agLazy)} · webtoon ${f(v.webtoon)} · eager ${f(v.agEager)} · fidelity mismatches ${v.agStructure?.fidelity?.mismatches ?? '–'}`;
          });
      case 'stress-gpu':
      case 'stress-heap':
        return [`Reached ${d.reachedMB ?? d.lastStartedStep} MB · stopped by: ${d.stoppedBy ?? d.interpretation}`];
    }
  } catch {
    /* fall through */
  }
  return [];
}

/* ---------- UI ---------- */

const app = document.getElementById('app')!;
const logEl = el('pre', { class: 'log' });
const panel = el('div', { class: 'panel' });
const cards = new Map<string, HTMLElement>();
let submitStatus: HTMLElement;

function log(msg: string) {
  const t = new Date().toLocaleTimeString();
  logEl.textContent = `[${t}] ${msg}\n` + (logEl.textContent ?? '').slice(0, 4000);
}

function hostingLabel(): string {
  const env = report.env as D;
  if (env.hosting?.embeddedInFrame) return 'Embedded (claude.ai artifact)';
  if (env.displayMode?.standalone || env.displayMode?.mediaStandalone) return 'Installed (Home Screen)';
  return 'Browser tab';
}

function renderCard(x: Experiment): HTMLElement {
  const r = report.results[x.id];
  const card = el('section', { class: `card ${r ? r.status : 'pending'}` });
  const runBtn = el('button', { class: x.risky ? 'danger' : 'primary' }, r ? 'Run again' : 'Run');
  runBtn.onclick = () => runOne(x);
  runBtn.disabled = running;
  const chips = el('div', { class: 'chips' });
  if (x.interactive) chips.append(el('span', { class: 'chip' }, 'interactive'));
  if (x.risky) chips.append(el('span', { class: 'chip warn' }, 'may reload page'));
  chips.append(el('span', { class: `chip status` }, r ? `${r.status} · ${Math.round(r.durationMs / 100) / 10}s` : 'not run'));
  card.append(el('div', { class: 'card-head' }, el('h3', {}, x.title), runBtn), chips, el('p', { class: 'summary' }, x.summary));
  if (r) {
    const lines = headline(x.id, r.data);
    if (r.error) lines.unshift(`Error: ${r.error}`);
    if (lines.length) card.append(el('ul', { class: 'headline' }, ...lines.map((l) => el('li', {}, l))));
    const det = el('details', {}, el('summary', {}, 'Raw data'), el('pre', {}, JSON.stringify(r.data, null, 2)));
    card.append(det);
  }
  return card;
}

function render() {
  app.innerHTML = '';
  const header = el(
    'header',
    {},
    el('h1', {}, 'OpenLive · Milestone 0 Platform Lab'),
    el('div', { class: 'meta' }, `Run ${report.runId} · ${hostingLabel()} · ${new Date(report.createdAt).toLocaleString()}`),
  );
  if (recovered)
    header.append(
      el('div', { class: 'banner' }, `Recovered: the previous load ended during “${recovered.experiment}” (step ${recovered.step}). Recorded as terminated.`),
    );

  const label = el('input', { type: 'text', placeholder: 'Device, e.g. “iPad 10th gen · iPadOS 18.1 · Pencil USB-C”', value: report.label });
  label.oninput = () => {
    report.label = label.value;
    saveReport(report);
  };
  const notes = el('textarea', { placeholder: 'Observations (e.g. “page zoomed during pinch”, “Scribble converted my stroke to text”)…', rows: '3' });
  notes.value = report.notes;
  notes.oninput = () => {
    report.notes = notes.value;
    saveReport(report);
  };

  const runAll = el('button', { class: 'primary big' }, 'Run all automatic tests (~2 min)');
  runAll.disabled = running;
  runAll.onclick = async () => {
    for (const x of AUTOMATIC) await runOne(x);
  };

  const section = (title: string, desc: string, xs: Experiment[]) => {
    const s = el('div', { class: 'group' }, el('h2', {}, title), el('p', { class: 'desc' }, desc));
    for (const x of xs) {
      const c = renderCard(x);
      cards.set(x.id, c);
      s.append(c);
    }
    return s;
  };

  submitStatus = el('div', { class: 'submit-status' });
  const submit = el('button', { class: 'primary big' }, 'Submit results to Claude');
  submit.onclick = submitToClaude;
  const copy = el('button', {}, 'Copy JSON');
  copy.onclick = async () => {
    try {
      await navigator.clipboard.writeText(reportJson(report));
      submitStatus.textContent = 'Copied.';
    } catch (e) {
      submitStatus.textContent = `Copy failed: ${(e as Error).message}`;
    }
  };
  const share = el('button', {}, 'Share / Save to Files');
  share.hidden = !!(report.env as D).hosting?.embeddedInFrame; // Web Share is refused inside the claude.ai frame
  share.onclick = async () => {
    const file = new File([reportJson(report)], `${report.runId}.json`, { type: 'application/json' });
    try {
      if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file], title: 'OpenLive M0 results' });
      else await downloadFile(file);
    } catch (e) {
      submitStatus.textContent = `Share: ${(e as Error).message}`;
    }
  };
  const dl = el('button', {}, 'Download JSON');
  dl.onclick = () => void downloadFile(new File([reportJson(report)], `${report.runId}.json`, { type: 'application/json' }));
  // In-page confirmation (confirm() is unavailable inside the claude.ai frame).
  const resetRow = el('div', { class: 'confirm-row' });
  const reset = el('button', { class: 'danger' }, 'Start a new run…');
  reset.onclick = () => {
    resetRow.innerHTML = '';
    const yes = el('button', { class: 'danger' }, 'Discard this run and start over');
    const no = el('button', {}, 'Keep this run');
    yes.onclick = () => {
      report = freshReport();
      saveReport(report);
      void collectEnv().then((env) => {
        report.env = env;
        saveReport(report);
        render();
      });
    };
    no.onclick = () => (resetRow.innerHTML = '');
    resetRow.append(el('span', {}, 'Results not yet submitted or saved will be lost.'), yes, no);
  };

  app.append(
    header,
    el('div', { class: 'row' }, label),
    el(
      'div',
      { class: 'group' },
      el('h2', {}, '1 · Automatic'),
      el('p', { class: 'desc' }, 'Keep the iPad awake, in landscape, on power if possible. Close other apps first.'),
      runAll,
    ),
    section('', '', AUTOMATIC),
    section('2 · Interactive', 'These need you: drawing with the Pencil and fingers, and the PSD import.', INTERACTIVE),
    section(
      '3 · Memory ceilings (run last)',
      'These deliberately exhaust memory. iPadOS may reload the page; reopen the lab and the result is recovered. Run each once.',
      RISKY,
    ),
    panel,
    el(
      'div',
      { class: 'group' },
      el('h2', {}, '4 · Send results'),
      notes,
      el('div', { class: 'row buttons' }, submit, share, copy, dl, reset),
      resetRow,
      submitStatus,
    ),
    el('h2', {}, 'Log'),
    logEl,
  );
}

interface DownloadsNs {
  save(o: { filename: string; data: Blob | string }): Promise<unknown>;
}

async function downloadFile(f: File) {
  const w = window as unknown as { claude?: { use(n: string): Promise<unknown> } };
  const dls = (w.claude ? await w.claude.use('downloads') : null) as DownloadsNs | null;
  if (dls) {
    try {
      await dls.save({ filename: f.name, data: f });
      submitStatus.textContent = `Saved ${f.name}.`;
    } catch (e) {
      submitStatus.textContent = `Save declined or failed: ${(e as Error).message}`;
    }
    return;
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(f);
  a.download = f.name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
}

async function runOne(x: Experiment) {
  if (running) return;
  running = true;
  render();
  const startedAt = new Date().toISOString();
  const t0 = performance.now();
  const crumb = makeCrumb(x.id, startedAt);
  const ac = new AbortController();
  panel.innerHTML = '';
  panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
  const ctx: Ctx = {
    report,
    panel,
    log,
    crumb,
    signal: ac.signal,
    startedAt,
    partial: (data) => setResult(report, x.id, { status: 'partial', startedAt, durationMs: performance.now() - t0, data }),
  };
  log(`▶ ${x.title}`);
  crumb(0, { phase: 'start' });
  try {
    const data = await x.run(ctx);
    setResult(report, x.id, { status: 'ok', startedAt, durationMs: performance.now() - t0, data });
    log(`✓ ${x.title}`);
  } catch (e) {
    const prev = report.results[x.id];
    setResult(report, x.id, {
      status: 'error',
      startedAt,
      durationMs: performance.now() - t0,
      data: prev?.status === 'partial' ? prev.data : {},
      error: `${(e as Error).name}: ${(e as Error).message}`,
    });
    log(`✗ ${x.title}: ${(e as Error).message}`);
  } finally {
    clearBreadcrumb();
    panel.innerHTML = '';
    running = false;
    render();
    cards.get(x.id)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
}

interface DbNs {
  collection(p: string): { doc(id: string): { set(d: Record<string, unknown>): Promise<void> } };
}

async function submitToClaude() {
  submitStatus.textContent = 'Connecting…';
  const w = window as unknown as { claude?: { use(n: string): Promise<unknown> } };
  const db = (w.claude ? await w.claude.use('db') : null) as DbNs | null;
  if (!db) {
    submitStatus.textContent =
      'Direct submission only works when this lab is opened from its claude.ai link. Use “Share / Save to Files” or “Copy JSON” and paste the results into the chat instead.';
    return;
  }
  const json = reportJson(report, false);
  if (json.length > 250_000) {
    submitStatus.textContent = `Report is ${Math.round(json.length / 1024)} KB (limit 250 KB). Use Share/Copy instead.`;
    return;
  }
  try {
    await db.collection('runs').doc(report.runId).set({ ...(JSON.parse(json) as Record<string, unknown>), submittedAt: new Date().toISOString() });
    submitStatus.textContent = `Submitted as ${report.runId}. Tell Claude in the chat that results are in.`;
  } catch (e) {
    submitStatus.textContent = `Submission failed (${(e as Error).message}). Use Share/Copy instead.`;
  }
}

/* ---------- boot ---------- */

render();
void collectEnv().then((env) => {
  report.env = env;
  saveReport(report);
  render();
});

// Prevent Safari page pinch-zoom globally so gesture tests are meaningful.
document.addEventListener('gesturestart', (e) => e.preventDefault());

if (import.meta.env.MODE === 'pages' && 'serviceWorker' in navigator && window.top === window.self) {
  const link = document.createElement('link');
  link.rel = 'manifest';
  link.href = './manifest.webmanifest';
  document.head.append(link);
  void navigator.serviceWorker.register('./sw.js').catch((e) => log(`service worker: ${e.message}`));
}

export { ALL };

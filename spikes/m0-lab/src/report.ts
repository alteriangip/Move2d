/**
 * Report store for the M0 lab.
 *
 * Results are written to localStorage after every experiment step so that a
 * run which gets the tab killed by the OS (the point of the stress tests)
 * still produces a result: a "breadcrumb" records the step in progress, and
 * on the next load an unfinished breadcrumb is converted into a
 * "terminated at step N" result.
 */

export interface ExperimentResult {
  status: 'ok' | 'error' | 'terminated' | 'skipped' | 'partial';
  startedAt: string;
  durationMs: number;
  data: Record<string, unknown>;
  error?: string;
}

export interface Report {
  schema: 1;
  runId: string;
  createdAt: string;
  updatedAt: string;
  label: string;
  env: Record<string, unknown>;
  results: Record<string, ExperimentResult>;
  notes: string;
}

export interface Breadcrumb {
  experiment: string;
  step: number;
  detail: Record<string, unknown>;
  startedAt: string;
  at: string;
}

const REPORT_KEY = 'openlive.m0.report';
const CRUMB_KEY = 'openlive.m0.breadcrumb';

function safeGet(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function safeSet(key: string, v: string): boolean {
  try {
    localStorage.setItem(key, v);
    return true;
  } catch {
    return false;
  }
}
function safeRemove(key: string): void {
  try {
    localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

/** True when localStorage works in this context (crash recovery depends on it). */
export function storageWorks(): boolean {
  const k = 'openlive.m0.probe';
  const ok = safeSet(k, '1') && safeGet(k) === '1';
  safeRemove(k);
  return ok;
}

function newRunId(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  const rand = Math.random().toString(36).slice(2, 7);
  return `run-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}-${rand}`;
}

/** Loads the current report or creates a new one. */
export function loadReport(): Report {
  const raw = safeGet(REPORT_KEY);
  if (raw) {
    try {
      const r = JSON.parse(raw) as Report;
      if (r.schema === 1) return r;
    } catch {
      /* fall through */
    }
  }
  return freshReport();
}

export function freshReport(): Report {
  const now = new Date().toISOString();
  return { schema: 1, runId: newRunId(), createdAt: now, updatedAt: now, label: '', env: {}, results: {}, notes: '' };
}

export function saveReport(r: Report): void {
  r.updatedAt = new Date().toISOString();
  safeSet(REPORT_KEY, JSON.stringify(r));
}

export function setResult(r: Report, id: string, res: ExperimentResult): void {
  r.results[id] = res;
  saveReport(r);
}

/** Writes a breadcrumb synchronously before a step that may crash the tab. */
export function breadcrumb(experiment: string, step: number, detail: Record<string, unknown>, startedAt: string): void {
  const c: Breadcrumb = { experiment, step, detail, startedAt, at: new Date().toISOString() };
  safeSet(CRUMB_KEY, JSON.stringify(c));
}

export function clearBreadcrumb(): void {
  safeRemove(CRUMB_KEY);
}

/**
 * If the previous page load died mid-experiment, converts the breadcrumb into
 * a "terminated" result and returns it.
 */
export function recoverCrash(r: Report): Breadcrumb | null {
  const raw = safeGet(CRUMB_KEY);
  if (!raw) return null;
  clearBreadcrumb();
  try {
    const c = JSON.parse(raw) as Breadcrumb;
    const started = Date.parse(c.startedAt);
    setResult(r, c.experiment, {
      status: 'terminated',
      startedAt: c.startedAt,
      durationMs: Date.parse(c.at) - started,
      data: {
        interpretation: 'The page was killed or reloaded while this step was running (most likely the OS memory limit).',
        lastStartedStep: c.step,
        ...c.detail,
      },
    });
    return c;
  } catch {
    return null;
  }
}

/** Serializes the report for export/submission. */
export function reportJson(r: Report, pretty = true): string {
  return JSON.stringify(r, null, pretty ? 2 : 0);
}

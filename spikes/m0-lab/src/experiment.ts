/** Shared experiment contract for the M0 lab. */
import type { Report } from './report';
import { breadcrumb, clearBreadcrumb } from './report';

export interface Ctx {
  report: Report;
  /** Area experiments may render interactive UI into. Cleared before each run. */
  panel: HTMLElement;
  log(msg: string): void;
  /** Persist a breadcrumb before a step that may kill the tab. */
  crumb(step: number, detail: Record<string, unknown>): void;
  /** Persist partial data so it survives a crash. */
  partial(data: Record<string, unknown>): void;
  signal: AbortSignal;
  startedAt: string;
}

export interface Experiment {
  id: string;
  title: string;
  summary: string;
  /** May crash/reload the page by design. */
  risky?: boolean;
  /** Needs the user to do something (e.g. draw with the Pencil). */
  interactive?: boolean;
  run(ctx: Ctx): Promise<Record<string, unknown>>;
}

export function makeCrumb(id: string, startedAt: string) {
  return (step: number, detail: Record<string, unknown>) => breadcrumb(id, step, detail, startedAt);
}

export { clearBreadcrumb };

export const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
export const raf = () => new Promise<number>((r) => requestAnimationFrame(r));

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else e.setAttribute(k, v);
  }
  for (const c of children) e.append(c);
  return e;
}

/** Rounds numbers in a value tree for compact reports. */
export function round(v: number, d = 2): number {
  const f = 10 ** d;
  return Math.round(v * f) / f;
}

export const MB = 1024 * 1024;

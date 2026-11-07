/**
 * Undo/redo over immutable documents. Because ops never mutate, a history
 * entry is just the previous Doc reference (structural sharing keeps this
 * cheap). Continuous edits (dragging, sliders) use begin/commit so one gesture
 * becomes one undo step.
 */
import type { Doc } from './types';

export interface History {
  past: { doc: Doc; label: string }[];
  future: { doc: Doc; label: string }[];
  /** doc at the start of an open transaction */
  pending: Doc | null;
}

export const MAX_HISTORY = 200;

export const emptyHistory = (): History => ({ past: [], future: [], pending: null });

export function record(h: History, before: Doc, label: string): History {
  const past = [...h.past, { doc: before, label }];
  if (past.length > MAX_HISTORY) past.shift();
  return { past, future: [], pending: null };
}

export function undo(h: History, current: Doc): { h: History; doc: Doc } | null {
  const last = h.past[h.past.length - 1];
  if (!last) return null;
  return { h: { past: h.past.slice(0, -1), future: [{ doc: current, label: last.label }, ...h.future], pending: null }, doc: last.doc };
}

export function redo(h: History, current: Doc): { h: History; doc: Doc } | null {
  const next = h.future[0];
  if (!next) return null;
  return { h: { past: [...h.past, { doc: current, label: next.label }], future: h.future.slice(1), pending: null }, doc: next.doc };
}

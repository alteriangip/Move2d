/**
 * Editor state (zustand). Holds the document, its image assets, undo history,
 * selection and UI state. Every document change goes through `apply` (one
 * undo step) or a begin/preview/commit transaction (one undo step for a
 * whole gesture), which is also what triggers autosave.
 */
import { create } from 'zustand';
import type { Asset, Doc, Id, Node } from '../engine/model/types';
import * as ops from '../engine/model/ops';
import { emptyHistory, record, undo as hUndo, redo as hRedo, type History } from '../engine/model/history';
import * as storage from '../engine/io/storage';

export type Tool = 'select' | 'hand';

export interface Toast {
  id: number;
  text: string;
  kind: 'info' | 'error';
}

interface State {
  doc: Doc | null;
  assets: Map<Id, Asset>;
  history: History;
  selection: Id[];
  tool: Tool;
  showGrid: boolean;
  leftOpen: boolean;
  rightOpen: boolean;
  saving: 'idle' | 'pending' | 'saving' | 'saved' | 'error';
  toasts: Toast[];
  /** bumps when the viewport should re-fit the document */
  fitRequest: number;

  setDoc(doc: Doc, assets: Map<Id, Asset>): void;
  closeDoc(): void;
  apply(label: string, f: (d: Doc) => Doc): void;
  begin(): void;
  preview(f: (d: Doc) => Doc): void;
  commit(label: string): void;
  cancel(): void;
  undo(): void;
  redo(): void;
  addAssets(assets: Asset[]): Promise<void>;
  select(ids: Id[]): void;
  setTool(t: Tool): void;
  toggle(k: 'showGrid' | 'leftOpen' | 'rightOpen'): void;
  setPanels(left: boolean, right: boolean): void;
  toast(text: string, kind?: Toast['kind']): void;
  requestFit(): void;
}

let toastSeq = 0;

export const useEditor = create<State>((set, get) => ({
  doc: null,
  assets: new Map(),
  history: emptyHistory(),
  selection: [],
  tool: 'select',
  showGrid: false,
  leftOpen: true,
  rightOpen: true,
  saving: 'idle',
  toasts: [],
  fitRequest: 0,

  setDoc(doc, assets) {
    set({ doc, assets, history: emptyHistory(), selection: [], fitRequest: get().fitRequest + 1 });
  },
  closeDoc() {
    set({ doc: null, assets: new Map(), history: emptyHistory(), selection: [] });
  },
  apply(label, f) {
    const { doc, history } = get();
    if (!doc) return;
    const next = f(doc);
    if (next === doc) return;
    set({ doc: next, history: record(history, doc, label), selection: get().selection.filter((id) => next.nodes[id]) });
    scheduleSave();
  },
  begin() {
    const { doc, history } = get();
    if (doc && !history.pending) set({ history: { ...history, pending: doc } });
  },
  preview(f) {
    const { doc } = get();
    if (doc) set({ doc: f(doc) });
  },
  commit(label) {
    const { doc, history } = get();
    if (!doc || !history.pending) return;
    if (history.pending === doc) return set({ history: { ...history, pending: null } });
    set({ history: record(history, history.pending, label) });
    scheduleSave();
  },
  cancel() {
    const { history } = get();
    if (history.pending) set({ doc: history.pending, history: { ...history, pending: null } });
  },
  undo() {
    const { doc, history } = get();
    if (!doc) return;
    const r = hUndo(history, doc);
    if (!r) return;
    set({ doc: r.doc, history: r.h, selection: get().selection.filter((id) => r.doc.nodes[id]) });
    scheduleSave();
  },
  redo() {
    const { doc, history } = get();
    if (!doc) return;
    const r = hRedo(history, doc);
    if (!r) return;
    set({ doc: r.doc, history: r.h, selection: get().selection.filter((id) => r.doc.nodes[id]) });
    scheduleSave();
  },
  async addAssets(assets) {
    const { doc } = get();
    const m = new Map(get().assets);
    for (const a of assets) m.set(a.id, a);
    set({ assets: m });
    if (doc) await storage.putAssets(doc.id, assets);
  },
  select(ids) {
    set({ selection: ids });
  },
  setTool(tool) {
    set({ tool });
  },
  toggle(k) {
    set({ [k]: !get()[k] } as Partial<State>);
  },
  setPanels(leftOpen, rightOpen) {
    set({ leftOpen, rightOpen });
  },
  toast(text, kind = 'info') {
    const id = ++toastSeq;
    set({ toasts: [...get().toasts, { id, text, kind }] });
    setTimeout(() => set({ toasts: get().toasts.filter((t) => t.id !== id) }), kind === 'error' ? 8000 : 3500);
  },
  requestFit() {
    set({ fitRequest: get().fitRequest + 1 });
  },
}));

/* ---------- autosave ---------- */

let saveTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleSave() {
  useEditor.setState({ saving: 'pending' });
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNow, 1200);
}

/** Saves the current document immediately (also called when the app is hidden). */
export async function saveNow(): Promise<void> {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  const { doc, history } = useEditor.getState();
  if (!doc || history.pending) return;
  useEditor.setState({ saving: 'saving' });
  try {
    await storage.saveDoc(doc);
    useEditor.setState({ saving: 'saved' });
  } catch (e) {
    useEditor.setState({ saving: 'error' });
    useEditor.getState().toast(`Could not save to this device: ${(e as Error).message}. Export the project to keep a copy.`, 'error');
  }
}

/* ---------- selectors ---------- */

export const selectedNodes = (s: Pick<State, 'doc' | 'selection'>): Node[] =>
  s.doc ? s.selection.map((id) => s.doc!.nodes[id]).filter(Boolean) : [];

export { ops };

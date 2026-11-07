/** OpenLive editor shell: toolbar, panels, viewport, dialogs and file flows. */
import { useCallback, useEffect, useRef, useState } from 'react';
import { useEditor, saveNow, ops } from './store';
import { Viewport, statsRef } from './components/Viewport';
import { Hierarchy } from './components/Hierarchy';
import { Inspector } from './components/Inspector';
import { ImportDialog, type ImportChoice } from './components/ImportDialog';
import { ProjectsDialog } from './components/ProjectsDialog';
import { PsdImportSession, buildNodes, importImageFile, selectedLayerKeys } from '../engine/io/psd-import';
import type { PsdStructure } from '../engine/io/psd-types';
import { readProject, writeProject } from '../engine/io/project-file';
import * as storage from '../engine/io/storage';
import { pickFile, saveFile, safeName } from './files';
import type { Asset, Doc } from '../engine/model/types';

const LAST_KEY = 'openlive.lastProject';
const remember = (id: string | null) => {
  try {
    if (id) localStorage.setItem(LAST_KEY, id);
    else localStorage.removeItem(LAST_KEY);
  } catch {
    /* storage unavailable: just don't remember */
  }
};

export function App() {
  const doc = useEditor((s) => s.doc);
  const leftOpen = useEditor((s) => s.leftOpen);
  const rightOpen = useEditor((s) => s.rightOpen);
  const toasts = useEditor((s) => s.toasts);
  const [projectsOpen, setProjectsOpen] = useState(false);
  const [booting, setBooting] = useState(true);
  const [psd, setPsd] = useState<{ session: PsdImportSession; structure: PsdStructure; name: string } | null>(null);
  const [progress, setProgress] = useState<{ done: number; total: number; name: string } | null>(null);
  const narrow = useNarrow();

  // Restore the last project on start.
  useEffect(() => {
    let id: string | null = null;
    try {
      id = localStorage.getItem(LAST_KEY);
    } catch {
      /* ignore */
    }
    (id ? storage.loadProject(id) : Promise.resolve(null))
      .then((p) => {
        if (p) openLoaded(p.doc, p.assets);
        else setProjectsOpen(true);
      })
      .catch(() => setProjectsOpen(true))
      .finally(() => setBooting(false));
  }, []);

  // Narrow (portrait) screens: panels become overlays, closed by default.
  useEffect(() => {
    useEditor.getState().setPanels(!narrow, !narrow);
  }, [narrow]);

  // Save when the app is hidden (switching apps, locking the iPad).
  useEffect(() => {
    const h = () => document.visibilityState === 'hidden' && void saveNow();
    document.addEventListener('visibilitychange', h);
    window.addEventListener('pagehide', h);
    return () => {
      document.removeEventListener('visibilitychange', h);
      window.removeEventListener('pagehide', h);
    };
  }, []);

  // Keyboard shortcuts (Magic Keyboard / desktop). Every action also has a button.
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT') return;
      const s = useEditor.getState();
      const mod = e.metaKey || e.ctrlKey;
      if (mod && e.key.toLowerCase() === 'z') {
        e.preventDefault();
        if (e.shiftKey) s.redo();
        else s.undo();
      } else if (mod && e.key.toLowerCase() === 'y') {
        e.preventDefault();
        s.redo();
      } else if ((e.key === 'Delete' || e.key === 'Backspace') && s.selection.length) {
        e.preventDefault();
        s.apply('Delete', (d) => ops.deleteNodes(d, s.selection));
      } else if (e.key === 'Escape') s.select([]);
      else if (e.key === 'v') s.setTool('select');
      else if (e.key === 'h') s.setTool('hand');
      else if (e.key === '0' && mod) {
        e.preventDefault();
        s.requestFit();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);

  const openLoaded = (d: Doc, assets: Map<string, Asset>) => {
    useEditor.getState().setDoc(d, assets);
    remember(d.id);
    // Drop stored images no longer used by the document (history is empty after opening).
    void storage.pruneAssets(d.id, ops.referencedImages(d));
  };

  const openProject = async (id: string) => {
    await saveNow();
    const p = await storage.loadProject(id);
    if (!p) return useEditor.getState().toast('That project could not be found on this device.', 'error');
    openLoaded(p.doc, p.assets);
    setProjectsOpen(false);
  };

  const newEmpty = async () => {
    await saveNow();
    const d = ops.emptyDoc('Untitled', 2048, 2048);
    await storage.saveDoc(d);
    openLoaded(d, new Map());
    setProjectsOpen(false);
  };

  const importFlow = useCallback(async () => {
    const f = await pickFile('.psd,.psb,.png,.jpg,.jpeg,.olive,image/png,image/jpeg,image/vnd.adobe.photoshop');
    if (!f) return;
    const s = useEditor.getState();
    const lower = f.name.toLowerCase();
    try {
      if (lower.endsWith('.olive')) {
        const { doc: d, assets } = readProject(new Uint8Array(await f.arrayBuffer()));
        // Imported projects get a fresh id so they never overwrite an existing one.
        const copy = { ...d, id: ops.newId() };
        await saveNow();
        await storage.saveDoc(copy);
        await storage.putAssets(copy.id, [...assets.values()]);
        openLoaded(copy, assets);
        setProjectsOpen(false);
        s.toast(`Opened “${copy.name}”.`);
      } else if (lower.endsWith('.psd') || lower.endsWith('.psb')) {
        const session = new PsdImportSession();
        const structure = await session.parse(await f.arrayBuffer());
        setProjectsOpen(false);
        setPsd({ session, structure, name: f.name });
      } else {
        const r = await importImageFile(f, s.doc);
        if (!s.doc) {
          const d = ops.emptyDoc(r.node.name, r.width, r.height);
          r.node.x = 0;
          r.node.y = 0;
          const withLayer = ops.insertNodes(d, [r.node], null, 0, [r.node.id]);
          await storage.saveDoc(withLayer);
          await storage.putAssets(withLayer.id, [r.asset]);
          openLoaded(withLayer, new Map([[r.asset.id, r.asset]]));
          setProjectsOpen(false);
        } else {
          await s.addAssets([r.asset]);
          s.apply('Import image', (d) => ops.insertNodes(d, [r.node], null, 0, [r.node.id]));
          s.select([r.node.id]);
        }
      }
    } catch (e) {
      s.toast(`Could not import “${f.name}”: ${(e as Error).message}`, 'error');
    }
  }, []);

  const finishPsd = async (choice: ImportChoice) => {
    if (!psd) return;
    const s = useEditor.getState();
    const keys = selectedLayerKeys(psd.structure.tree, choice.excluded);
    try {
      setProgress({ done: 0, total: keys.length, name: '' });
      const { images, warnings } = await psd.session.decode(keys, (done, total, name) => setProgress({ done, total, name }));
      if (choice.asNewProject || !s.doc) {
        await saveNow();
        let d = ops.emptyDoc(psd.name.replace(/\.(psd|psb)$/i, ''), psd.structure.width, psd.structure.height);
        const b = buildNodes(psd.structure.tree, images, choice.excluded, null);
        d = ops.insertNodes(d, b.nodes, null, 0, b.topIds);
        await storage.saveDoc(d);
        await storage.putAssets(d.id, b.assets);
        openLoaded(d, new Map(b.assets.map((a) => [a.id, a])));
      } else {
        const groupId = ops.newId();
        const b = buildNodes(psd.structure.tree, images, choice.excluded, groupId);
        await s.addAssets(b.assets);
        s.apply('Import PSD', (d) =>
          ops.insertNodes(
            d,
            [{ id: groupId, kind: 'group', name: psd.name.replace(/\.(psd|psb)$/i, ''), parentId: null, visible: true, locked: false, opacity: 1, childIds: b.topIds, expanded: true }, ...b.nodes],
            null,
            0,
            [groupId],
          ),
        );
        s.select([groupId]);
      }
      const n = images.size;
      s.toast(`Imported ${n} layer${n === 1 ? '' : 's'}.${warnings.length ? ` ${warnings.length} notice(s): ${warnings.slice(0, 2).join(' ')}` : ''}`, warnings.length ? 'error' : 'info');
    } catch (e) {
      s.toast(`Import failed: ${(e as Error).message}`, 'error');
    } finally {
      psd.session.dispose();
      setPsd(null);
      setProgress(null);
    }
  };

  const exportProject = async () => {
    const s = useEditor.getState();
    if (!s.doc) return;
    try {
      await saveNow();
      const bytes = writeProject(s.doc, s.assets);
      const r = await saveFile(`${safeName(s.doc.name)}.olive`, bytes, 'application/zip');
      const size = bytes.length < 1048576 ? `${Math.max(1, Math.round(bytes.length / 1024))} KB` : `${(bytes.length / 1048576).toFixed(1)} MB`;
      if (r !== 'cancelled') s.toast(`Exported ${safeName(s.doc.name)}.olive (${size}).`);
    } catch (e) {
      s.toast(`Export failed: ${(e as Error).message}`, 'error');
    }
  };

  const panelOverlay = narrow;
  return (
    <div className={`app ${panelOverlay ? 'narrow' : ''}`}>
      <Toolbar onProjects={() => setProjectsOpen(true)} onImport={importFlow} onExport={exportProject} />
      <div className="workspace">
        {leftOpen ? (
          <aside className={`panel left ${panelOverlay ? 'overlay' : ''}`}>
            <Hierarchy />
          </aside>
        ) : null}
        <main className="center">
          <Viewport />
          {!doc && !booting ? <div className="empty-hint">Open or import a project to start.</div> : null}
        </main>
        {rightOpen ? (
          <aside className={`panel right ${panelOverlay ? 'overlay' : ''}`}>
            <Inspector />
          </aside>
        ) : null}
      </div>
      <StatusBar />
      {projectsOpen ? (
        <ProjectsDialog canClose={!!doc} onClose={() => setProjectsOpen(false)} onOpen={openProject} onNew={newEmpty} onImportFile={importFlow} />
      ) : null}
      {psd ? (
        <ImportDialog
          fileName={psd.name}
          structure={psd.structure}
          canAddToCurrent={!!doc}
          progress={progress}
          onCancel={() => {
            psd.session.dispose();
            setPsd(null);
          }}
          onImport={finishPsd}
        />
      ) : null}
      <div className="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.kind}`}>
            {t.text}
          </div>
        ))}
      </div>
    </div>
  );
}

function Toolbar({ onProjects, onImport, onExport }: { onProjects: () => void; onImport: () => void; onExport: () => void }) {
  const doc = useEditor((s) => s.doc);
  const canUndo = useEditor((s) => s.history.past.length > 0);
  const canRedo = useEditor((s) => s.history.future.length > 0);
  const undoLabel = useEditor((s) => s.history.past[s.history.past.length - 1]?.label);
  const redoLabel = useEditor((s) => s.history.future[0]?.label);
  const tool = useEditor((s) => s.tool);
  const grid = useEditor((s) => s.showGrid);
  const leftOpen = useEditor((s) => s.leftOpen);
  const rightOpen = useEditor((s) => s.rightOpen);
  const s = useEditor.getState;
  return (
    <header className="toolbar">
      <button onClick={onProjects} title="Projects">
        ☰ <span className="lbl">Projects</span>
      </button>
      <button onClick={onImport}>
        ⤓ <span className="lbl">Import</span>
      </button>
      <button onClick={onExport} disabled={!doc}>
        ⤴ <span className="lbl">Export</span>
      </button>
      <span className="sep" />
      <button onClick={() => s().undo()} disabled={!canUndo} title={undoLabel ? `Undo ${undoLabel}` : 'Undo'}>
        ↶ <span className="lbl">Undo</span>
      </button>
      <button onClick={() => s().redo()} disabled={!canRedo} title={redoLabel ? `Redo ${redoLabel}` : 'Redo'}>
        ↷ <span className="lbl">Redo</span>
      </button>
      <span className="sep" />
      <button className={tool === 'select' ? 'on' : ''} aria-pressed={tool === 'select'} onClick={() => s().setTool('select')}>
        ➚ <span className="lbl">Select</span>
      </button>
      <button className={tool === 'hand' ? 'on' : ''} aria-pressed={tool === 'hand'} onClick={() => s().setTool('hand')}>
        ✋ <span className="lbl">Hand</span>
      </button>
      <button onClick={() => s().requestFit()} disabled={!doc}>
        ⤢ <span className="lbl">Fit</span>
      </button>
      <button className={grid ? 'on' : ''} aria-pressed={grid} onClick={() => s().toggle('showGrid')}>
        ▦ <span className="lbl">Grid</span>
      </button>
      <span className="spacer" />
      <span className="doc-name">{doc?.name ?? 'OpenLive'}</span>
      <span className="spacer" />
      <button className={leftOpen ? 'on' : ''} aria-pressed={leftOpen} onClick={() => s().toggle('leftOpen')}>
        <span className="lbl">Layers</span>
        <span className="sym">◧</span>
      </button>
      <button className={rightOpen ? 'on' : ''} aria-pressed={rightOpen} onClick={() => s().toggle('rightOpen')}>
        <span className="lbl">Inspector</span>
        <span className="sym">◨</span>
      </button>
    </header>
  );
}

function StatusBar() {
  const saving = useEditor((s) => s.saving);
  const sel = useEditor((s) => s.selection.length);
  const [, force] = useState(0);
  const fps = useFps();
  useEffect(() => {
    const t = setInterval(() => force((x) => x + 1), 500);
    return () => clearInterval(t);
  }, []);
  const st = statsRef();
  const saveText = { idle: '', pending: 'Unsaved changes', saving: 'Saving…', saved: 'Saved on this iPad', error: 'Save failed' }[saving];
  return (
    <footer className="status">
      <span>{Math.round(st.zoom * 100)}%</span>
      <span>{sel ? `${sel} selected` : 'Nothing selected'}</span>
      <span className={saving === 'error' ? 'bad' : ''}>{saveText}</span>
      <span className="spacer" />
      <span title="Estimated GPU memory used by layer textures">
        {st.textures} textures · {st.textureMB.toFixed(0)} MB
      </span>
      <span>{fps} fps</span>
    </footer>
  );
}

function useFps(): number {
  const [fps, setFps] = useState(0);
  const frames = useRef(0);
  useEffect(() => {
    let raf = 0;
    const tick = () => {
      frames.current++;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    const t = setInterval(() => {
      setFps(frames.current);
      frames.current = 0;
    }, 1000);
    return () => {
      cancelAnimationFrame(raf);
      clearInterval(t);
    };
  }, []);
  return fps;
}

function useNarrow(): boolean {
  const q = '(max-width: 900px)';
  const [m, setM] = useState(() => matchMedia(q).matches);
  useEffect(() => {
    const mq = matchMedia(q);
    const h = () => setM(mq.matches);
    mq.addEventListener('change', h);
    return () => mq.removeEventListener('change', h);
  }, []);
  return m;
}

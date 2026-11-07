/** Projects stored on this device: open, delete (with confirmation), create. */
import { useEffect, useState } from 'react';
import * as storage from '../../engine/io/storage';

export function ProjectsDialog({
  onOpen,
  onClose,
  onNew,
  onImportFile,
  canClose,
}: {
  onOpen: (id: string) => void;
  onClose: () => void;
  onNew: () => void;
  onImportFile: () => void;
  canClose: boolean;
}) {
  const [list, setList] = useState<storage.ProjectMeta[] | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [est, setEst] = useState<Awaited<ReturnType<typeof storage.storageEstimate>>>(null);
  const refresh = () => {
    storage.listProjects().then(setList, () => setList([]));
    storage.storageEstimate().then(setEst);
  };
  useEffect(refresh, []);
  return (
    <div className="modal-backdrop">
      <div className="modal" role="dialog" aria-label="Projects">
        <h2>Projects on this iPad</h2>
        <div className="modal-actions left">
          <button className="primary" onClick={onImportFile}>
            Import PSD or image…
          </button>
          <button onClick={onNew}>New empty project</button>
        </div>
        {list === null ? <p className="hint">Loading…</p> : null}
        {list?.length === 0 ? <p className="hint">No saved projects yet. Import a PSD to start one; it is saved automatically.</p> : null}
        <ul className="project-list">
          {list?.map((p) => (
            <li key={p.id}>
              <button className="project" onClick={() => onOpen(p.id)}>
                <b>{p.name}</b>
                <span>
                  {p.width}×{p.height} · {p.layerCount} layers · {new Date(p.updatedAt).toLocaleString()}
                </span>
              </button>
              {confirm === p.id ? (
                <>
                  <button
                    className="danger"
                    onClick={async () => {
                      await storage.deleteProject(p.id);
                      setConfirm(null);
                      refresh();
                    }}
                  >
                    Delete forever
                  </button>
                  <button onClick={() => setConfirm(null)}>Keep</button>
                </>
              ) : (
                <button className="danger ghost" onClick={() => setConfirm(p.id)}>
                  Delete…
                </button>
              )}
            </li>
          ))}
        </ul>
        {est ? (
          <p className="hint">
            Storage used {est.usageMB.toFixed(0)} MB of {est.quotaMB.toFixed(0)} MB.{' '}
            {est.persisted ? 'Storage is persistent.' : 'iPadOS may clear this storage if the app is unused for a while, so export important projects (Export button).'}
          </p>
        ) : null}
        {canClose ? (
          <div className="modal-actions">
            <button onClick={onClose}>Close</button>
          </div>
        ) : null}
      </div>
    </div>
  );
}

/**
 * PSD import preview: shows the layer tree with include/exclude switches and
 * warnings, then decodes the chosen layers in the worker with progress.
 */
import { useMemo, useState } from 'react';
import type { ImportNode, PsdStructure } from '../../engine/io/psd-types';
import { selectedLayerKeys } from '../../engine/io/psd-import';

export interface ImportChoice {
  excluded: Set<string>;
  asNewProject: boolean;
}

export function ImportDialog({
  fileName,
  structure,
  canAddToCurrent,
  progress,
  onCancel,
  onImport,
}: {
  fileName: string;
  structure: PsdStructure;
  canAddToCurrent: boolean;
  progress: { done: number; total: number; name: string } | null;
  onCancel: () => void;
  onImport: (c: ImportChoice) => void;
}) {
  const [excluded, setExcluded] = useState<Set<string>>(() => new Set());
  const [asNew, setAsNew] = useState(!canAddToCurrent);
  const count = useMemo(() => selectedLayerKeys(structure.tree, excluded).length, [structure, excluded]);
  const toggle = (k: string) => {
    const s = new Set(excluded);
    if (s.has(k)) s.delete(k);
    else s.add(k);
    setExcluded(s);
  };
  return (
    <div className="modal-backdrop">
      <div className="modal" role="dialog" aria-label="Import PSD">
        <h2>Import “{fileName}”</h2>
        <p className="hint">
          {structure.width} × {structure.height} px · {structure.layerCount} layers · {structure.bitsPerChannel}-bit. Every layer stays a separate, editable layer.
        </p>
        {structure.warnings.length ? (
          <details className="warnings" open={structure.warnings.length <= 3}>
            <summary>{structure.warnings.length} notice{structure.warnings.length > 1 ? 's' : ''}</summary>
            <ul>
              {structure.warnings.map((w) => (
                <li key={w}>{w}</li>
              ))}
            </ul>
          </details>
        ) : null}
        <div className="import-tree">
          <Tree nodes={structure.tree} excluded={excluded} toggle={toggle} depth={0} />
        </div>
        {canAddToCurrent ? (
          <div className="toggles">
            <button className={`toggle ${asNew ? 'on' : ''}`} aria-pressed={asNew} onClick={() => setAsNew(true)}>
              New project
            </button>
            <button className={`toggle ${!asNew ? 'on' : ''}`} aria-pressed={!asNew} onClick={() => setAsNew(false)}>
              Add to current project
            </button>
          </div>
        ) : null}
        {progress ? (
          <div className="progress">
            <div className="bar" style={{ width: `${(100 * progress.done) / Math.max(1, progress.total)}%` }} />
            <span>
              Importing {progress.done}/{progress.total}: {progress.name}
            </span>
          </div>
        ) : null}
        <div className="modal-actions">
          <button onClick={onCancel} disabled={!!progress}>
            Cancel
          </button>
          <button className="primary" disabled={!count || !!progress} onClick={() => onImport({ excluded, asNewProject: asNew })}>
            Import {count} layer{count === 1 ? '' : 's'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Tree({ nodes, excluded, toggle, depth }: { nodes: ImportNode[]; excluded: Set<string>; toggle: (k: string) => void; depth: number }) {
  return (
    <ul>
      {nodes.map((n) => {
        const off = excluded.has(n.key) || !!n.skipReason;
        return (
          <li key={n.key}>
            <button className={`import-row ${off ? 'off' : ''}`} style={{ paddingLeft: 8 + depth * 18 }} disabled={!!n.skipReason} onClick={() => toggle(n.key)}>
              <span className="check" aria-hidden>
                {off ? '☐' : '☑'}
              </span>
              <span className="kind" aria-hidden>
                {n.kind === 'group' ? '▤' : '▢'}
              </span>
              <span className="name">{n.name}</span>
              <span className="meta">{n.skipReason ?? (n.kind === 'layer' ? `${n.width}×${n.height}${n.visible ? '' : ' · hidden'}` : n.visible ? '' : 'hidden')}</span>
            </button>
            {n.children && !excluded.has(n.key) ? <Tree nodes={n.children} excluded={excluded} toggle={toggle} depth={depth + 1} /> : null}
          </li>
        );
      })}
    </ul>
  );
}

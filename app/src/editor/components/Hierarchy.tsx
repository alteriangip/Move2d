/**
 * Layer hierarchy: groups (Parts) and layers, top-to-bottom like Photoshop.
 * Tap selects (Shift/⌘ or the multi-select toggle adds), long-press opens
 * actions, eye/lock toggle visibility and locking, double-tap renames.
 */
import { useState } from 'react';
import { useEditor, ops } from '../store';
import type { Doc, Id, Node } from '../../engine/model/types';
import { Menu, type MenuItem } from './Menu';
import { useLongPress } from './useLongPress';
import { nodeActions } from './actions';

export function Hierarchy() {
  const doc = useEditor((s) => s.doc);
  const [multi, setMulti] = useState(false);
  if (!doc) return <div className="panel-empty">No project open.</div>;
  return (
    <div className="hierarchy">
      <div className="panel-head">
        <h2>Layers</h2>
        <button className={`chip-btn ${multi ? 'on' : ''}`} onClick={() => setMulti(!multi)} aria-pressed={multi}>
          Multi-select
        </button>
      </div>
      {doc.rootIds.length === 0 ? <div className="panel-empty">Import a PSD or image to add layers.</div> : null}
      <ul className="tree" role="tree">
        {doc.rootIds.map((id) => (
          <Row key={id} doc={doc} id={id} depth={0} multi={multi} />
        ))}
      </ul>
    </div>
  );
}

function Row({ doc, id, depth, multi }: { doc: Doc; id: Id; depth: number; multi: boolean }) {
  const n = doc.nodes[id] as Node;
  const selected = useEditor((s) => s.selection.includes(id));
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const [renaming, setRenaming] = useState(false);
  const lp = useLongPress((x, y) => {
    const s = useEditor.getState();
    if (!s.selection.includes(id)) s.select([id]);
    setMenu({ x, y });
  });
  const lastTap = useState({ t: 0 })[0];

  const onClick = (e: React.MouseEvent) => {
    if (lp.consumed()) return;
    const s = useEditor.getState();
    const now = performance.now();
    if (now - lastTap.t < 350 && s.selection.length === 1 && s.selection[0] === id) {
      setRenaming(true);
      return;
    }
    lastTap.t = now;
    if (multi || e.shiftKey || e.metaKey || e.ctrlKey) s.select(s.selection.includes(id) ? s.selection.filter((x) => x !== id) : [...s.selection, id]);
    else s.select([id]);
  };

  const items: MenuItem[] = menu ? [{ label: 'Rename', onSelect: () => setRenaming(true) }, ...nodeActions(useEditor.getState().selection.length ? useEditor.getState().selection : [id])] : [];

  return (
    <li role="treeitem" aria-selected={selected} aria-expanded={n.kind === 'group' ? n.expanded : undefined}>
      <div className={`row ${selected ? 'sel' : ''} ${n.visible ? '' : 'hidden-node'}`} style={{ paddingLeft: 8 + depth * 18 }} onClick={onClick} {...lp}>
        {n.kind === 'group' ? (
          <button
            className="twisty"
            aria-label={n.expanded ? 'Collapse' : 'Expand'}
            onClick={(e) => {
              e.stopPropagation();
              // expanding is a view preference: do not create an undo step
              useEditor.setState((s) => (s.doc ? { doc: { ...s.doc, nodes: { ...s.doc.nodes, [id]: { ...n, expanded: !n.expanded } } } } : {}));
            }}
          >
            {n.expanded ? '▾' : '▸'}
          </button>
        ) : (
          <span className="twisty-space" />
        )}
        <span className={`kind ${n.kind}`} aria-hidden>
          {n.kind === 'group' ? '▤' : '▢'}
        </span>
        {renaming ? (
          <input
            className="rename"
            autoFocus
            defaultValue={n.name}
            onClick={(e) => e.stopPropagation()}
            onBlur={(e) => {
              setRenaming(false);
              const v = e.currentTarget.value.trim();
              if (v && v !== n.name) useEditor.getState().apply('Rename', (d) => ops.updateNode(d, id, { name: v }));
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') e.currentTarget.blur();
              if (e.key === 'Escape') setRenaming(false);
            }}
          />
        ) : (
          <span className="name">{n.name}</span>
        )}
        <button
          className={`icon-btn ${n.locked ? 'on' : ''}`}
          aria-label={n.locked ? 'Unlock' : 'Lock'}
          aria-pressed={n.locked}
          onClick={(e) => {
            e.stopPropagation();
            useEditor.getState().apply(n.locked ? 'Unlock' : 'Lock', (d) => ops.updateNode(d, id, { locked: !n.locked }));
          }}
        >
          {n.locked ? '🔒' : '🔓'}
        </button>
        <button
          className={`icon-btn ${n.visible ? '' : 'off'}`}
          aria-label={n.visible ? 'Hide' : 'Show'}
          aria-pressed={n.visible}
          onClick={(e) => {
            e.stopPropagation();
            useEditor.getState().apply(n.visible ? 'Hide' : 'Show', (d) => ops.updateNode(d, id, { visible: !n.visible }));
          }}
        >
          {n.visible ? '●' : '○'}
        </button>
      </div>
      {menu ? <Menu x={menu.x} y={menu.y} items={items} onClose={() => setMenu(null)} /> : null}
      {n.kind === 'group' && n.expanded ? (
        <ul role="group">
          {n.childIds.map((c) => (
            <Row key={c} doc={doc} id={c} depth={depth + 1} multi={multi} />
          ))}
        </ul>
      ) : null}
    </li>
  );
}

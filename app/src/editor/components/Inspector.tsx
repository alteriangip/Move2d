/** Contextual properties of the selection (or the document when nothing is selected). */
import { useEditor, ops } from '../store';
import type { BlendMode, Doc, LayerNode, Node } from '../../engine/model/types';
import { boundsOf } from '../hit-test';
import { nodeActions } from './actions';

export function Inspector() {
  const doc = useEditor((s) => s.doc);
  const selection = useEditor((s) => s.selection);
  if (!doc) return <div className="panel-empty">No project open.</div>;
  const nodes = selection.map((id) => doc.nodes[id]).filter(Boolean) as Node[];
  return (
    <div className="inspector">
      <div className="panel-head">
        <h2>{nodes.length === 0 ? 'Project' : nodes.length === 1 ? (nodes[0].kind === 'group' ? 'Group' : 'Layer') : `${nodes.length} selected`}</h2>
      </div>
      {nodes.length === 0 ? <DocProps doc={doc} /> : nodes.length === 1 ? <NodeProps doc={doc} node={nodes[0]} /> : <MultiProps doc={doc} ids={selection} />}
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
    </label>
  );
}

function DocProps({ doc }: { doc: Doc }) {
  const layers = Object.values(doc.nodes).filter((n) => n.kind === 'layer').length;
  const groups = Object.values(doc.nodes).length - layers;
  return (
    <div className="props">
      <Field label="Name">
        <TextInput value={doc.name} onCommit={(v) => useEditor.getState().apply('Rename project', (d) => ({ ...d, name: v }))} />
      </Field>
      <div className="readout">
        <span>Canvas</span>
        <b>
          {doc.width} × {doc.height} px
        </b>
      </div>
      <div className="readout">
        <span>Contents</span>
        <b>
          {layers} layers · {groups} groups
        </b>
      </div>
      <p className="hint">Tap a layer on the canvas or in the Layers panel to edit it. Drag with the Pencil to move it.</p>
    </div>
  );
}

function NodeProps({ doc, node }: { doc: Doc; node: Node }) {
  const s = useEditor.getState;
  const id = node.id;
  return (
    <div className="props">
      <Field label="Name">
        <TextInput key={id} value={node.name} onCommit={(v) => s().apply('Rename', (d) => ops.updateNode(d, id, { name: v }))} />
      </Field>
      <div className="toggles">
        <Toggle label="Visible" on={node.visible} onChange={(v) => s().apply(v ? 'Show' : 'Hide', (d) => ops.updateNode(d, id, { visible: v }))} />
        <Toggle label="Locked" on={node.locked} onChange={(v) => s().apply(v ? 'Lock' : 'Unlock', (d) => ops.updateNode(d, id, { locked: v }))} />
      </div>
      <Field label={`Opacity ${Math.round(node.opacity * 100)}%`}>
        <input
          type="range"
          min={0}
          max={100}
          step={1}
          value={Math.round(node.opacity * 100)}
          onPointerDown={() => s().begin()}
          onChange={(e) => {
            const v = Number(e.currentTarget.value) / 100;
            if (!s().history.pending) s().begin();
            s().preview((d) => ops.updateNode(d, id, { opacity: v }));
          }}
          onPointerUp={() => s().commit('Opacity')}
          onKeyUp={() => s().commit('Opacity')}
          onBlur={() => s().commit('Opacity')}
        />
      </Field>
      {node.kind === 'layer' ? <LayerProps node={node} /> : <GroupProps doc={doc} id={id} />}
      <div className="actions">
        {nodeActions([id]).map((a) => (
          <button key={a.label} className={a.danger ? 'danger' : ''} disabled={a.disabled} onClick={a.onSelect}>
            {a.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function LayerProps({ node }: { node: LayerNode }) {
  const s = useEditor.getState;
  const id = node.id;
  return (
    <>
      <div className="row2">
        <Field label="X">
          <NumberInput value={node.x} onCommit={(v) => s().apply('Move layer', (d) => ops.updateNode<LayerNode>(d, id, { x: v }))} />
        </Field>
        <Field label="Y">
          <NumberInput value={node.y} onCommit={(v) => s().apply('Move layer', (d) => ops.updateNode<LayerNode>(d, id, { y: v }))} />
        </Field>
      </div>
      <div className="readout">
        <span>Size</span>
        <b>
          {node.width} × {node.height} px
        </b>
      </div>
      <Field label="Blend mode">
        <select value={node.blendMode} onChange={(e) => s().apply('Blend mode', (d) => ops.updateNode<LayerNode>(d, id, { blendMode: e.currentTarget.value as BlendMode }))}>
          <option value="normal">Normal</option>
          <option value="multiply">Multiply</option>
          <option value="additive">Additive</option>
        </select>
      </Field>
      {node.clipping ? <p className="hint">Clipped to the layer below in the PSD. Clipping masks are drawn from Milestone 2; the setting is kept.</p> : null}
    </>
  );
}

function GroupProps({ doc, id }: { doc: Doc; id: string }) {
  const b = boundsOf(doc, [id]);
  const n = doc.nodes[id];
  return (
    <div className="readout">
      <span>Contains</span>
      <b>
        {n.kind === 'group' ? `${n.childIds.length} item${n.childIds.length === 1 ? '' : 's'}` : ''}{b ? ` · ${Math.round(b.w)} × ${Math.round(b.h)} px` : ''}
      </b>
    </div>
  );
}

function MultiProps({ ids }: { doc: Doc; ids: string[] }) {
  return (
    <div className="props">
      <div className="actions">
        {nodeActions(ids)
          .filter((a) => !a.disabled)
          .map((a) => (
            <button key={a.label} className={a.danger ? 'danger' : ''} onClick={a.onSelect}>
              {a.label}
            </button>
          ))}
      </div>
    </div>
  );
}

function Toggle({ label, on, onChange }: { label: string; on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button className={`toggle ${on ? 'on' : ''}`} aria-pressed={on} onClick={() => onChange(!on)}>
      {label}
    </button>
  );
}

function TextInput({ value, onCommit }: { value: string; onCommit: (v: string) => void }) {
  return (
    <input
      type="text"
      defaultValue={value}
      key={value}
      onBlur={(e) => {
        const v = e.currentTarget.value.trim();
        if (v && v !== value) onCommit(v);
      }}
      onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
    />
  );
}

function NumberInput({ value, onCommit }: { value: number; onCommit: (v: number) => void }) {
  return (
    <input
      type="text"
      inputMode="numeric"
      defaultValue={String(value)}
      key={value}
      onBlur={(e) => {
        const v = Math.round(Number(e.currentTarget.value));
        if (Number.isFinite(v) && v !== value) onCommit(v);
        else e.currentTarget.value = String(value);
      }}
      onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()}
    />
  );
}

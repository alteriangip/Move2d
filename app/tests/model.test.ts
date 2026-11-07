import { describe, it, expect } from 'vitest';
import * as ops from '../src/engine/model/ops';
import { emptyHistory, record, undo, redo } from '../src/engine/model/history';
import type { Doc, GroupNode, LayerNode } from '../src/engine/model/types';

const layer = (id: string, parentId: string | null = null): LayerNode => ({
  id, kind: 'layer', name: id, parentId, visible: true, locked: false, opacity: 1,
  imageId: `img-${id}`, x: 0, y: 0, width: 10, height: 10, blendMode: 'normal', clipping: false,
});
const group = (id: string, childIds: string[], parentId: string | null = null): GroupNode => ({
  id, kind: 'group', name: id, parentId, visible: true, locked: false, opacity: 1, childIds, expanded: true,
});

/** root: [G(a, b), c] */
function sample(): Doc {
  let d = ops.emptyDoc('t', 100, 100);
  d = ops.insertNodes(d, [group('G', ['a', 'b']), layer('a', 'G'), layer('b', 'G'), layer('c')], null, 0, ['G', 'c']);
  return d;
}

describe('document operations', () => {
  it('sample is structurally valid', () => expect(ops.validate(sample())).toEqual([]));

  it('drawList is bottom-to-top and multiplies group opacity, skipping hidden', () => {
    let d = sample();
    d = ops.updateNode(d, 'G', { opacity: 0.5 });
    expect(ops.drawList(d).map((x) => x.layer.id)).toEqual(['c', 'b', 'a']);
    expect(ops.drawList(d).find((x) => x.layer.id === 'a')!.opacity).toBe(0.5);
    d = ops.updateNode(d, 'G', { visible: false });
    expect(ops.drawList(d).map((x) => x.layer.id)).toEqual(['c']);
  });

  it('moves, shifts and refuses cycles', () => {
    let d = sample();
    d = ops.moveNode(d, 'c', 'G', 0);
    expect((d.nodes.G as GroupNode).childIds).toEqual(['c', 'a', 'b']);
    expect(d.rootIds).toEqual(['G']);
    expect(ops.validate(d)).toEqual([]);
    d = ops.shiftNode(d, 'c', 1);
    expect((d.nodes.G as GroupNode).childIds).toEqual(['a', 'c', 'b']);
    const before = d;
    expect(ops.moveNode(d, 'G', 'G', 0)).toBe(before);
    d = ops.groupNodes(d, ['a'], 'Inner').doc;
    const inner = Object.values(d.nodes).find((n) => n.name === 'Inner')!;
    expect(ops.moveNode(d, 'G', inner.id, 0)).toBe(d); // cannot move a group into its own descendant
  });

  it('groups and ungroups, preserving order and validity', () => {
    let d = sample();
    const r = ops.groupNodes(d, ['c', 'G']);
    d = r.doc;
    expect(d.rootIds).toEqual([r.groupId]);
    expect((d.nodes[r.groupId] as GroupNode).childIds).toEqual(['G', 'c']);
    expect(ops.validate(d)).toEqual([]);
    d = ops.ungroup(d, r.groupId);
    expect(d.rootIds).toEqual(['G', 'c']);
    expect(d.nodes[r.groupId]).toBeUndefined();
    expect(ops.validate(d)).toEqual([]);
  });

  it('deletes recursively', () => {
    const d = ops.deleteNodes(sample(), ['G']);
    expect(Object.keys(d.nodes)).toEqual(['c']);
    expect(ops.validate(d)).toEqual([]);
    expect([...ops.referencedImages(d)]).toEqual(['img-c']);
  });

  it('never mutates its input', () => {
    const d = sample();
    const snapshot = JSON.stringify(d);
    ops.moveNode(d, 'c', 'G', 1);
    ops.updateNode(d, 'a', { name: 'x' });
    ops.deleteNodes(d, ['a']);
    ops.groupNodes(d, ['a', 'c']);
    expect(JSON.stringify(d)).toBe(snapshot);
  });
});

describe('undo / redo', () => {
  it('round-trips a sequence of edits', () => {
    let d = sample();
    let h = emptyHistory();
    const steps: [string, (x: Doc) => Doc][] = [
      ['rename', (x) => ops.updateNode(x, 'a', { name: 'Arm' })],
      ['move', (x) => ops.moveNode(x, 'c', 'G', 0)],
      ['delete', (x) => ops.deleteNodes(x, ['b'])],
    ];
    const states = [d];
    for (const [label, f] of steps) {
      const next = f(d);
      h = record(h, d, label);
      d = next;
      states.push(d);
    }
    for (let i = states.length - 2; i >= 0; i--) {
      const r = undo(h, d)!;
      h = r.h;
      d = r.doc;
      expect(d).toBe(states[i]);
    }
    expect(undo(h, d)).toBeNull();
    for (let i = 1; i < states.length; i++) {
      const r = redo(h, d)!;
      h = r.h;
      d = r.doc;
      expect(d).toBe(states[i]);
    }
  });
  it('a new edit clears the redo stack', () => {
    const d = sample();
    let h = record(emptyHistory(), d, 'x');
    h = undo(h, ops.updateNode(d, 'a', { name: 'y' }))!.h;
    expect(h.future.length).toBe(1);
    h = record(h, d, 'z');
    expect(h.future.length).toBe(0);
  });
});

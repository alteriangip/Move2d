/**
 * Pure document operations. Every function returns a new Doc (structural
 * sharing; the input is never mutated), which makes undo/redo a matter of
 * keeping previous Doc references.
 */
import { nanoid } from 'nanoid';
import type { Doc, GroupNode, Id, LayerNode, Node } from './types';
import { FORMAT_VERSION } from './types';

export const newId = () => nanoid(12);

export function emptyDoc(name: string, width: number, height: number): Doc {
  const now = new Date().toISOString();
  return { formatVersion: FORMAT_VERSION, id: newId(), name, width, height, nodes: {}, rootIds: [], createdAt: now, updatedAt: now };
}

/** Children list of a parent (null = root). */
export function childrenOf(doc: Doc, parentId: Id | null): Id[] {
  if (parentId === null) return doc.rootIds;
  const p = doc.nodes[parentId];
  return p && p.kind === 'group' ? p.childIds : [];
}

function withChildren(doc: Doc, parentId: Id | null, ids: Id[]): Doc {
  if (parentId === null) return { ...doc, rootIds: ids };
  const p = doc.nodes[parentId] as GroupNode;
  return { ...doc, nodes: { ...doc.nodes, [parentId]: { ...p, childIds: ids } } };
}

/** Depth-first, top-to-bottom list of node ids. */
export function walk(doc: Doc, parentId: Id | null = null, out: Id[] = []): Id[] {
  for (const id of childrenOf(doc, parentId)) {
    out.push(id);
    const n = doc.nodes[id];
    if (n.kind === 'group') walk(doc, id, out);
  }
  return out;
}

/** Layers in draw order (bottom first), with effective visibility and opacity. */
export function drawList(doc: Doc): { layer: LayerNode; opacity: number }[] {
  const out: { layer: LayerNode; opacity: number }[] = [];
  const rec = (ids: Id[], parentOpacity: number) => {
    for (let i = ids.length - 1; i >= 0; i--) {
      const n = doc.nodes[ids[i]];
      if (!n || !n.visible) continue;
      const o = parentOpacity * n.opacity;
      if (n.kind === 'group') rec(n.childIds, o);
      else out.push({ layer: n, opacity: o });
    }
  };
  rec(doc.rootIds, 1);
  return out;
}

export function isAncestor(doc: Doc, maybeAncestor: Id, id: Id): boolean {
  let cur = doc.nodes[id]?.parentId ?? null;
  while (cur) {
    if (cur === maybeAncestor) return true;
    cur = doc.nodes[cur]?.parentId ?? null;
  }
  return false;
}

/** Inserts nodes (already in doc.nodes or provided) under a parent at an index. */
export function insertNodes(doc: Doc, nodes: Node[], parentId: Id | null, index: number, topLevelIds: Id[]): Doc {
  const map = { ...doc.nodes };
  for (const n of nodes) map[n.id] = n;
  let d: Doc = { ...doc, nodes: map };
  const list = childrenOf(d, parentId).slice();
  list.splice(Math.max(0, Math.min(index, list.length)), 0, ...topLevelIds);
  d = withChildren(d, parentId, list);
  return touch(d);
}

export function updateNode<T extends Node>(doc: Doc, id: Id, patch: Partial<T>): Doc {
  const n = doc.nodes[id];
  if (!n) return doc;
  return touch({ ...doc, nodes: { ...doc.nodes, [id]: { ...n, ...patch } as Node } });
}

/** Removes nodes and all their descendants. Returns the doc and removed image ids. */
export function deleteNodes(doc: Doc, ids: Id[]): Doc {
  const toRemove = new Set<Id>();
  const collect = (id: Id) => {
    toRemove.add(id);
    const n = doc.nodes[id];
    if (n?.kind === 'group') n.childIds.forEach(collect);
  };
  ids.forEach(collect);
  const nodes: Record<Id, Node> = {};
  for (const [id, n] of Object.entries(doc.nodes)) {
    if (toRemove.has(id)) continue;
    nodes[id] = n.kind === 'group' && n.childIds.some((c) => toRemove.has(c)) ? { ...n, childIds: n.childIds.filter((c) => !toRemove.has(c)) } : n;
  }
  return touch({ ...doc, nodes, rootIds: doc.rootIds.filter((r) => !toRemove.has(r)) });
}

/** Moves a node to a new parent/index. Refuses to move a group into itself. */
export function moveNode(doc: Doc, id: Id, newParentId: Id | null, index: number): Doc {
  const n = doc.nodes[id];
  if (!n) return doc;
  if (newParentId === id || (newParentId && isAncestor(doc, id, newParentId))) return doc;
  if (newParentId && doc.nodes[newParentId]?.kind !== 'group') return doc;
  let d = withChildren(doc, n.parentId, childrenOf(doc, n.parentId).filter((c) => c !== id));
  const list = childrenOf(d, newParentId).slice();
  list.splice(Math.max(0, Math.min(index, list.length)), 0, id);
  d = withChildren(d, newParentId, list);
  d = { ...d, nodes: { ...d.nodes, [id]: { ...d.nodes[id], parentId: newParentId } } };
  return touch(d);
}

/** Moves a node one step up (-1) or down (+1) among its siblings. */
export function shiftNode(doc: Doc, id: Id, delta: -1 | 1): Doc {
  const n = doc.nodes[id];
  if (!n) return doc;
  const sib = childrenOf(doc, n.parentId);
  const i = sib.indexOf(id);
  const j = i + delta;
  if (j < 0 || j >= sib.length) return doc;
  return moveNode(doc, id, n.parentId, j);
}

/** Wraps nodes (siblings or not) into a new group placed where the first one was. */
export function groupNodes(doc: Doc, ids: Id[], name = 'Group'): { doc: Doc; groupId: Id } {
  const valid = ids.filter((id) => doc.nodes[id] && !ids.some((o) => o !== id && isAncestor(doc, o, id)));
  if (!valid.length) return { doc, groupId: '' };
  const order = walk(doc);
  valid.sort((a, b) => order.indexOf(a) - order.indexOf(b));
  const first = doc.nodes[valid[0]];
  const parentId = first.parentId;
  const index = childrenOf(doc, parentId).indexOf(first.id);
  const groupId = newId();
  const group: GroupNode = { id: groupId, kind: 'group', name, parentId, visible: true, locked: false, opacity: 1, childIds: [], expanded: true };
  let d = insertNodes(doc, [group], parentId, index, [groupId]);
  valid.forEach((id, k) => (d = moveNode(d, id, groupId, k)));
  return { doc: d, groupId };
}

/** Removes a group, moving its children into its parent at its position. */
export function ungroup(doc: Doc, groupId: Id): Doc {
  const g = doc.nodes[groupId];
  if (!g || g.kind !== 'group') return doc;
  const parentId = g.parentId;
  let index = childrenOf(doc, parentId).indexOf(groupId);
  let d = doc;
  for (const c of g.childIds) d = moveNode(d, c, parentId, index++);
  return deleteNodes(d, [groupId]);
}

/** Image ids referenced by any layer. */
export function referencedImages(doc: Doc): Set<Id> {
  const s = new Set<Id>();
  for (const n of Object.values(doc.nodes)) if (n.kind === 'layer') s.add(n.imageId);
  return s;
}

function touch(d: Doc): Doc {
  return { ...d, updatedAt: new Date().toISOString() };
}

/** Structural integrity check used by tests and on load. Returns problems found. */
export function validate(doc: Doc): string[] {
  const problems: string[] = [];
  const seen = new Set<Id>();
  const visit = (ids: Id[], parent: Id | null) => {
    for (const id of ids) {
      const n = doc.nodes[id];
      if (!n) {
        problems.push(`missing node ${id}`);
        continue;
      }
      if (seen.has(id)) problems.push(`node ${id} appears twice`);
      seen.add(id);
      if (n.parentId !== parent) problems.push(`node ${id} parentId ${n.parentId} != ${parent}`);
      if (n.kind === 'group') visit(n.childIds, id);
    }
  };
  visit(doc.rootIds, null);
  for (const id of Object.keys(doc.nodes)) if (!seen.has(id)) problems.push(`orphan node ${id}`);
  return problems;
}

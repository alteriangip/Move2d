/** Node actions shared by the hierarchy context menu and the inspector. */
import { useEditor, ops } from '../store';
import type { Id } from '../../engine/model/types';
import type { MenuItem } from './Menu';

export function nodeActions(ids: Id[]): MenuItem[] {
  const s = useEditor.getState();
  const doc = s.doc;
  if (!doc || !ids.length) return [];
  const single = ids.length === 1 ? doc.nodes[ids[0]] : null;
  const siblings = single ? ops.childrenOf(doc, single.parentId) : [];
  const idx = single ? siblings.indexOf(single.id) : -1;
  const parent = single?.parentId ? doc.nodes[single.parentId] : null;
  const items: MenuItem[] = [
    { label: 'Move up', disabled: !single || idx <= 0, onSelect: () => s.apply('Move up', (d) => ops.shiftNode(d, ids[0], -1)) },
    { label: 'Move down', disabled: !single || idx < 0 || idx >= siblings.length - 1, onSelect: () => s.apply('Move down', (d) => ops.shiftNode(d, ids[0], 1)) },
    {
      label: 'Group',
      onSelect: () => {
        let gid = '';
        s.apply('Group', (d) => {
          const r = ops.groupNodes(d, ids, 'Group');
          gid = r.groupId;
          return r.doc;
        });
        if (gid) s.select([gid]);
      },
    },
  ];
  if (single?.kind === 'group') items.push({ label: 'Ungroup', onSelect: () => s.apply('Ungroup', (d) => ops.ungroup(d, single.id)) });
  if (parent) {
    const pIdx = ops.childrenOf(doc, parent.parentId).indexOf(parent.id);
    items.push({ label: 'Move out of group', onSelect: () => s.apply('Move out of group', (d) => ops.moveNode(d, ids[0], parent.parentId, pIdx)), disabled: !single });
  }
  // Move into the group directly above, if there is one: lets you parent without drag and drop.
  if (single && idx > 0) {
    const above = doc.nodes[siblings[idx - 1]];
    if (above.kind === 'group')
      items.push({ label: `Move into “${above.name}”`, onSelect: () => s.apply('Move into group', (d) => ops.moveNode(d, single.id, above.id, above.childIds.length)) });
  }
  items.push({
    label: ids.length > 1 ? `Delete ${ids.length} items` : 'Delete',
    danger: true,
    onSelect: () => {
      s.apply('Delete', (d) => ops.deleteNodes(d, ids));
      s.select([]);
    },
  });
  return items;
}

import { describe, it, expect } from 'vitest';
import { zipSync, strToU8 } from 'fflate';
import { readProject, writeProject, ProjectFileError } from '../src/engine/io/project-file';
import * as ops from '../src/engine/model/ops';
import type { Asset, LayerNode } from '../src/engine/model/types';

function fixture() {
  let d = ops.emptyDoc('Fixture ✎', 800, 600);
  const assets = new Map<string, Asset>();
  const nodes: LayerNode[] = [];
  for (let i = 0; i < 3; i++) {
    const imageId = `img${i}`;
    const bytes = new Uint8Array(100 + i).map((_, k) => (k * 7 + i) & 255).buffer;
    assets.set(imageId, { id: imageId, width: 10 + i, height: 20, mime: 'image/png', bytes });
    nodes.push({ id: `l${i}`, kind: 'layer', name: `Layer ${i}`, parentId: null, visible: i !== 1, locked: i === 2, opacity: 0.25 * (i + 1), imageId, x: i * 5, y: i ? -i : 0, width: 10 + i, height: 20, blendMode: i ? 'multiply' : 'normal', clipping: i === 1 });
  }
  d = ops.insertNodes(d, nodes, null, 0, nodes.map((n) => n.id));
  const g = ops.groupNodes(d, ['l0', 'l1'], 'Head');
  return { doc: g.doc, assets };
}

describe('.olive project file', () => {
  it('round-trips the document and image bytes exactly', () => {
    const { doc, assets } = fixture();
    const r = readProject(writeProject(doc, assets));
    expect(r.doc).toEqual(doc);
    expect(r.assets.size).toBe(3);
    for (const [id, a] of assets) {
      const b = r.assets.get(id)!;
      expect(new Uint8Array(b.bytes)).toEqual(new Uint8Array(a.bytes));
      expect([b.width, b.height, b.mime]).toEqual([a.width, a.height, a.mime]);
    }
  });
  it('is byte-stable: save(load(save(d))) === save(d)', () => {
    const { doc, assets } = fixture();
    const once = writeProject(doc, assets);
    const r = readProject(once);
    expect(writeProject(r.doc, r.assets)).toEqual(once);
  });
  it('omits images no layer uses', () => {
    const { doc, assets } = fixture();
    const d2 = ops.deleteNodes(doc, ['l2']);
    expect(readProject(writeProject(d2, assets)).assets.has('img2')).toBe(false);
  });
  it('rejects garbage, missing parts, newer formats and damaged structure with clear errors', () => {
    expect(() => readProject(new Uint8Array([1, 2, 3]))).toThrow(ProjectFileError);
    expect(() => readProject(zipSync({ 'x.txt': strToU8('hi') }))).toThrow(/project.json is missing/);
    expect(() => readProject(zipSync({ 'project.json': strToU8('{"formatVersion": 99, "doc": {}}') }))).toThrow(/newer OpenLive/);
    const { doc, assets } = fixture();
    const broken = { ...doc, rootIds: [...doc.rootIds, 'ghost'] };
    expect(() => readProject(writeProject(broken as typeof doc, assets))).toThrow(/damaged/);
    const files = { 'project.json': strToU8(JSON.stringify({ formatVersion: 1, doc, assets: [] })) };
    expect(() => readProject(zipSync(files))).toThrow(/not in the archive/);
  });
});

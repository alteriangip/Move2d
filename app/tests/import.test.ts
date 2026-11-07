import { describe, it, expect } from 'vitest';
import { buildNodes, selectedLayerKeys } from '../src/engine/io/psd-import';
import type { DecodedImage, ImportNode } from '../src/engine/io/psd-types';
import * as ops from '../src/engine/model/ops';
import { twoPointSimilarity, apply, invert, mul, zoomAt } from '../src/engine/math/affine';

const L = (key: string, name: string, extra: Partial<ImportNode> = {}): ImportNode => ({
  key, name, kind: 'layer', visible: true, opacity: 1, blendMode: 'normal', clipping: false, left: 100, top: 50, width: 40, height: 30, ...extra,
});
const tree: ImportNode[] = [
  { ...L('0', 'Head'), kind: 'group', children: [L('0/0', 'Eye ✎'), L('0/1', 'Hair', { visible: false, opacity: 0.5, blendMode: 'multiply' })] },
  L('1', 'Adjust', { skipReason: 'Adjustment layer (no pixels)' }),
  L('2', 'Body', { clipping: true }),
];
const img = (key: string, left = 2, top = 3): DecodedImage => ({ key, left, top, width: 10, height: 12, png: new ArrayBuffer(8) });

describe('PSD import mapping', () => {
  it('selects importable layers, honoring exclusions and skips', () => {
    expect(selectedLayerKeys(tree, new Set())).toEqual(['0/0', '0/1', '2']);
    expect(selectedLayerKeys(tree, new Set(['0']))).toEqual(['2']);
  });
  it('preserves names, order, hierarchy, visibility, opacity, blend, clipping and positions', () => {
    const images = new Map(['0/0', '0/1', '2'].map((k) => [k, img(k)]));
    const r = buildNodes(tree, images, new Set(), null);
    let d = ops.emptyDoc('p', 500, 500);
    d = ops.insertNodes(d, r.nodes, null, 0, r.topIds);
    expect(ops.validate(d)).toEqual([]);
    const names = ops.walk(d).map((id) => d.nodes[id].name);
    expect(names).toEqual(['Head', 'Eye ✎', 'Hair', 'Body']);
    const hair = Object.values(d.nodes).find((n) => n.name === 'Hair')!;
    expect(hair).toMatchObject({ visible: false, opacity: 0.5, blendMode: 'multiply', x: 102, y: 53, width: 10, height: 12 });
    expect(Object.values(d.nodes).find((n) => n.name === 'Body')).toMatchObject({ clipping: true });
    expect(r.assets.length).toBe(3);
  });
  it('drops groups whose layers were all excluded or failed', () => {
    const r = buildNodes(tree, new Map([['2', img('2')]]), new Set(), null);
    expect(r.nodes.map((n) => n.name)).toEqual(['Body']);
  });
});

describe('view transforms', () => {
  it('two-finger similarity keeps both contacts under the fingers', () => {
    const m = twoPointSimilarity([10, 20], [110, 20], [50, 50], [50, 250]);
    expect(apply(m, 10, 20)).toEqual([50, 50].map((v) => expect.closeTo(v, 9)));
    expect(apply(m, 110, 20)).toEqual([50, 250].map((v) => expect.closeTo(v, 9)));
  });
  it('invert and zoomAt behave', () => {
    const m = mul(zoomAt([2, 0, 0, 2, 10, 5], 1.5, 100, 100), [1, 0, 0, 1, 3, 4]);
    const [x, y] = apply(m, 7, 9);
    const back = apply(invert(m), x, y);
    expect(back[0]).toBeCloseTo(7, 9);
    expect(back[1]).toBeCloseTo(9, 9);
    // zoomAt keeps the pivot fixed
    const z = zoomAt([1, 0, 0, 1, 0, 0], 3, 40, 60);
    expect(apply(z, 40, 60)).toEqual([40, 60]);
  });
});

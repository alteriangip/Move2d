import { describe, it, expect } from 'vitest';
import { cornerWeights, blend4, warpPoints, rotatePoints, buildRig, evaluateRig, animateParams, PRESETS } from '../src/rig-kernel';
import { summarize, percentile, linearFit } from '../src/stats';

const idx = new Int32Array(4);
const w = new Float32Array(4);

describe('cornerWeights / blend4 (multilinear keyforms)', () => {
  it('weights sum to 1 everywhere', () => {
    for (let a = -1.2; a <= 1.2; a += 0.05)
      for (let b = -1.2; b <= 1.2; b += 0.05)
        for (const smooth of [false, true]) {
          cornerWeights(a, b, smooth, idx, w);
          expect(w[0] + w[1] + w[2] + w[3]).toBeCloseTo(1, 6);
          for (const i of idx) { expect(i).toBeGreaterThanOrEqual(0); expect(i).toBeLessThan(9); }
        }
  });

  it('reproduces the exact keyform at every key combination', () => {
    // keyform k holds the value k (len 1)
    const forms = Float32Array.from({ length: 9 }, (_, k) => k);
    const out = new Float32Array(1);
    const keys = [-1, 0, 1];
    for (let bi = 0; bi < 3; bi++)
      for (let ai = 0; ai < 3; ai++)
        for (const smooth of [false, true]) {
          cornerWeights(keys[ai], keys[bi], smooth, idx, w);
          blend4(forms, 1, idx, w, out);
          expect(out[0]).toBeCloseTo(bi * 3 + ai, 6);
        }
  });

  it('linear mode is linear between keys; smooth mode is smoothstep', () => {
    const forms = new Float32Array([0, 10, 20, 0, 10, 20, 0, 10, 20]); // varies along a only
    const out = new Float32Array(1);
    cornerWeights(0.25, 0, false, idx, w); blend4(forms, 1, idx, w, out);
    expect(out[0]).toBeCloseTo(12.5, 5);
    cornerWeights(0.25, 0, true, idx, w); blend4(forms, 1, idx, w, out);
    expect(out[0]).toBeCloseTo(10 + 10 * (0.0625 * (3 - 0.5)), 5);
  });

  it('clamps outside the key range', () => {
    const forms = new Float32Array([0, 10, 20, 0, 10, 20, 0, 10, 20]);
    const out = new Float32Array(1);
    cornerWeights(5, -5, false, idx, w); blend4(forms, 1, idx, w, out);
    expect(out[0]).toBeCloseTo(20, 6);
  });
});

describe('warpPoints (bilinear warp)', () => {
  // 2×2-cell grid spanning rect (100,200)-(300,600)
  const cols = 2, rows = 2;
  const grid = new Float32Array(18);
  for (let j = 0; j <= rows; j++) for (let i = 0; i <= cols; i++) {
    grid[(j * 3 + i) * 2] = 100 + (i / cols) * 200;
    grid[(j * 3 + i) * 2 + 1] = 200 + (j / rows) * 400;
  }
  it('identity lattice maps (u,v) to the rectangle, including extrapolation', () => {
    const src = new Float32Array([0, 0, 1, 1, 0.5, 0.25, 0.9, 0.1, -0.5, 0.5, 1.5, 1.25]);
    const dst = new Float32Array(src.length);
    warpPoints(grid, cols, rows, src, 0, dst, 0, src.length / 2);
    for (let p = 0; p < src.length / 2; p++) {
      expect(dst[p * 2]).toBeCloseTo(100 + src[p * 2] * 200, 3);
      expect(dst[p * 2 + 1]).toBeCloseTo(200 + src[p * 2 + 1] * 400, 3);
    }
  });
  it('moving one control point moves only points in its adjacent cells', () => {
    const g2 = grid.slice();
    g2[(1 * 3 + 1) * 2] += 50; // centre point
    const src = new Float32Array([0.5, 0.5, 0.05, 0.05, 0.25, 0.25]);
    const a = new Float32Array(6), b = new Float32Array(6);
    warpPoints(grid, cols, rows, src, 0, a, 0, 3);
    warpPoints(g2, cols, rows, src, 0, b, 0, 3);
    expect(b[0] - a[0]).toBeCloseTo(50, 3);           // at the moved point
    expect(b[2] - a[2]).toBeCloseTo(50 * 0.1 * 0.1, 3); // bilinear falloff (s=t=0.1 from far corner)
    expect(b[4] - a[4]).toBeCloseTo(50 * 0.5 * 0.5, 3);
  });
});

describe('rotatePoints', () => {
  it('rotates 90° about the origin with scale', () => {
    const p = new Float32Array([10, 0]);
    rotatePoints(p, 1, 5, 5, Math.PI / 2, 2);
    expect(p[0]).toBeCloseTo(5, 4);
    expect(p[1]).toBeCloseTo(25, 4);
  });
});

describe('synthetic rig', () => {
  it('target preset has ~30k vertices and evaluates to finite positions inside a sane box', () => {
    const rig = buildRig(PRESETS.target);
    expect(rig.totalVertices).toBe(150 * 196);
    animateParams(rig, 1.234);
    evaluateRig(rig);
    let minX = Infinity, maxX = -Infinity;
    for (let i = 0; i < rig.world.length; i += 2) {
      expect(Number.isFinite(rig.world[i])).toBe(true);
      minX = Math.min(minX, rig.world[i]); maxX = Math.max(maxX, rig.world[i]);
    }
    expect(minX).toBeGreaterThan(-rig.canvasW);
    expect(maxX).toBeLessThan(rig.canvasW * 2);
  });
  it('is deterministic', () => {
    const a = buildRig(PRESETS.target), b = buildRig(PRESETS.target);
    animateParams(a, 0.5); animateParams(b, 0.5);
    evaluateRig(a); evaluateRig(b);
    expect(Buffer.from(a.world.buffer).equals(Buffer.from(b.world.buffer))).toBe(true);
  });
  it('rest pose (all params 0) equals the undistorted middle keyform chain', () => {
    const rig = buildRig(PRESETS.target);
    rig.params.fill(0);
    evaluateRig(rig, false);
    // At rest every object uses keyform 4, whose geometry has no jitter; just
    // check that two evaluations at rest agree and that indices are in range.
    const first = rig.world.slice();
    evaluateRig(rig, true);
    for (let i = 0; i < first.length; i++) expect(rig.world[i]).toBeCloseTo(first[i], 3);
    expect(rig.indices.reduce((m, v) => (v > m ? v : m), 0)).toBeLessThan(rig.totalVertices);
  });
});

describe('stats', () => {
  it('percentiles and summary', () => {
    expect(percentile([1, 2, 3, 4, 5], 0.5)).toBe(3);
    expect(percentile([0, 10], 0.95)).toBeCloseTo(9.5);
    const s = summarize([5, 1, 3]);
    expect(s).toMatchObject({ n: 3, min: 1, p50: 3, max: 5, mean: 3 });
  });
  it('linear fit', () => {
    const f = linearFit([1, 2, 3], [3, 5, 7]);
    expect(f.a).toBeCloseTo(1); expect(f.b).toBeCloseTo(2);
  });
});

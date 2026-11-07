import { describe, it, expect } from 'vitest';
import { twoPointSimilarity } from '../src/exp-nav';

const apply = (m: number[], p: [number, number]) => [m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5]];

describe('twoPointSimilarity (pinch/pan/rotate)', () => {
  it('maps both start contacts onto the current contacts exactly', () => {
    const cases: [number, number][][] = [
      [[0, 0], [100, 0], [10, 10], [210, 10]],      // pan + 2× zoom
      [[50, 50], [150, 50], [50, 50], [50, 150]],   // 90° rotation
      [[3, 7], [40, -2], [-20, 15], [33, 80]],      // arbitrary
    ];
    for (const [p1, p2, q1, q2] of cases) {
      const m = twoPointSimilarity(p1, p2, q1, q2);
      const a = apply(m, p1), b = apply(m, p2);
      expect(a[0]).toBeCloseTo(q1[0], 6); expect(a[1]).toBeCloseTo(q1[1], 6);
      expect(b[0]).toBeCloseTo(q2[0], 6); expect(b[1]).toBeCloseTo(q2[1], 6);
    }
  });
  it('is a similarity (no shear, uniform scale)', () => {
    const m = twoPointSimilarity([0, 0], [10, 0], [5, 5], [5, 35]);
    expect(m[0]).toBeCloseTo(m[3], 9);
    expect(m[1]).toBeCloseTo(-m[2], 9);
    expect(Math.hypot(m[0], m[1])).toBeCloseTo(3, 9);
  });
});

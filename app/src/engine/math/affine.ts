/**
 * 2D affine transforms. M = [a, b, c, d, e, f] maps (x, y) to
 * (a·x + c·y + e, b·x + d·y + f), matching Canvas2D setTransform.
 */
export type Affine = [number, number, number, number, number, number];

export const IDENTITY: Affine = [1, 0, 0, 1, 0, 0];

/** Returns m·n (apply n first, then m). */
export function mul(m: Affine, n: Affine): Affine {
  return [
    m[0] * n[0] + m[2] * n[1],
    m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3],
    m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4],
    m[1] * n[4] + m[3] * n[5] + m[5],
  ];
}

export function apply(m: Affine, x: number, y: number): [number, number] {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}

export function invert(m: Affine): Affine {
  const det = m[0] * m[3] - m[1] * m[2];
  if (Math.abs(det) < 1e-12) throw new Error('singular transform');
  const a = m[3] / det,
    b = -m[1] / det,
    c = -m[2] / det,
    d = m[0] / det;
  return [a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5])];
}

/** Uniform scale factor of a similarity transform. */
export const scaleOf = (m: Affine) => Math.hypot(m[0], m[1]);

/** Rotation angle (radians) of a similarity transform. */
export const angleOf = (m: Affine) => Math.atan2(m[1], m[0]);

/** Scales about a fixed screen point. */
export function zoomAt(m: Affine, factor: number, px: number, py: number): Affine {
  return mul([factor, 0, 0, factor, px - factor * px, py - factor * py], m);
}

/**
 * Similarity transform (screen space) mapping segment p1→p2 onto q1→q2:
 * the two-finger pan / pinch / rotate gesture.
 */
export function twoPointSimilarity(
  p1: [number, number],
  p2: [number, number],
  q1: [number, number],
  q2: [number, number],
): Affine {
  const pdx = p2[0] - p1[0],
    pdy = p2[1] - p1[1];
  const qdx = q2[0] - q1[0],
    qdy = q2[1] - q1[1];
  const pl = Math.hypot(pdx, pdy) || 1e-6;
  const s = Math.hypot(qdx, qdy) / pl;
  const r = Math.atan2(qdy, qdx) - Math.atan2(pdy, pdx);
  const c = Math.cos(r) * s,
    si = Math.sin(r) * s;
  return [c, si, -si, c, q1[0] - (c * p1[0] - si * p1[1]), q1[1] - (si * p1[0] + c * p1[1])];
}

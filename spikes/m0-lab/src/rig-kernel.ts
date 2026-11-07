/**
 * Representative CPU rig evaluator used by the M0 deformation benchmark.
 *
 * It implements the same mathematics proposed in docs/01-architecture.md
 * (multilinear keyform blending, bilinear warp mapping, rotation deformer
 * affine) over a synthetic but realistically shaped hierarchy:
 *
 *   RotationDeformer (root) → parent Warp → child Warp → ArtMesh
 *
 * It is spike code: the production evaluator will live in packages/rig, but
 * the per-frame cost profile (typed arrays, zero allocation, all objects dirty)
 * is intentionally the same so the benchmark is predictive.
 */

/** Deterministic PRNG (mulberry32) so every device benchmarks the same rig. */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Keys used on every binding axis. */
export const KEYS = [-1, 0, 1] as const;

/**
 * Computes the four corner indices and weights for a 2-parameter, 3×3 keyform
 * grid at parameter values (a, b). Writes into `outIdx`/`outW` (length 4).
 * `smooth` applies smoothstep to the axis weights.
 */
export function cornerWeights(
  a: number,
  b: number,
  smooth: boolean,
  outIdx: Int32Array,
  outW: Float32Array,
): void {
  // Segment 0 covers keys [-1, 0], segment 1 covers (0, 1]; values clamp to the end keys.
  const ca = a < -1 ? -1 : a > 1 ? 1 : a;
  const cb = b < -1 ? -1 : b > 1 ? 1 : b;
  const ai = ca <= 0 ? 0 : 1;
  const bi = cb <= 0 ? 0 : 1;
  let ta = ca - KEYS[ai];
  let tb = cb - KEYS[bi];
  if (smooth) {
    ta = ta * ta * (3 - 2 * ta);
    tb = tb * tb * (3 - 2 * tb);
  }
  // row-major: index = bIndex * 3 + aIndex
  outIdx[0] = bi * 3 + ai;
  outIdx[1] = bi * 3 + ai + 1;
  outIdx[2] = (bi + 1) * 3 + ai;
  outIdx[3] = (bi + 1) * 3 + ai + 1;
  outW[0] = (1 - ta) * (1 - tb);
  outW[1] = ta * (1 - tb);
  outW[2] = (1 - ta) * tb;
  outW[3] = ta * tb;
}

/**
 * Blends `len` floats from the 4 selected keyforms stored contiguously in
 * `forms` (each keyform is `len` floats) into `out`.
 */
export function blend4(
  forms: Float32Array,
  len: number,
  idx: Int32Array,
  w: Float32Array,
  out: Float32Array,
): void {
  const o0 = idx[0] * len,
    o1 = idx[1] * len,
    o2 = idx[2] * len,
    o3 = idx[3] * len;
  const w0 = w[0],
    w1 = w[1],
    w2 = w[2],
    w3 = w[3];
  for (let k = 0; k < len; k++) {
    out[k] = forms[o0 + k] * w0 + forms[o1 + k] * w1 + forms[o2 + k] * w2 + forms[o3 + k] * w3;
  }
}

/**
 * Bilinear warp mapping of points (u,v) in normalized grid space through a
 * world-space control grid of (cols+1)×(rows+1) points. Points outside [0,1]
 * extrapolate linearly from the edge cells.
 *
 * Reads `count` points from `src` at `srcOff`, writes to `dst` at `dstOff`.
 */
export function warpPoints(
  grid: Float32Array,
  cols: number,
  rows: number,
  src: Float32Array,
  srcOff: number,
  dst: Float32Array,
  dstOff: number,
  count: number,
): void {
  const stride = (cols + 1) * 2;
  for (let p = 0; p < count; p++) {
    const u = src[srcOff + p * 2] * cols;
    const v = src[srcOff + p * 2 + 1] * rows;
    let i = Math.floor(u);
    let j = Math.floor(v);
    if (i < 0) i = 0;
    else if (i > cols - 1) i = cols - 1;
    if (j < 0) j = 0;
    else if (j > rows - 1) j = rows - 1;
    const s = u - i;
    const t = v - j;
    const c00 = j * stride + i * 2;
    const c10 = c00 + 2;
    const c01 = c00 + stride;
    const c11 = c01 + 2;
    const a = (1 - s) * (1 - t),
      b = s * (1 - t),
      c = (1 - s) * t,
      d = s * t;
    dst[dstOff + p * 2] = grid[c00] * a + grid[c10] * b + grid[c01] * c + grid[c11] * d;
    dst[dstOff + p * 2 + 1] =
      grid[c00 + 1] * a + grid[c10 + 1] * b + grid[c01 + 1] * c + grid[c11 + 1] * d;
  }
}

/** Applies origin + R(angle)·scale·p to `count` points in place. */
export function rotatePoints(
  pts: Float32Array,
  count: number,
  ox: number,
  oy: number,
  angle: number,
  scale: number,
): void {
  const c = Math.cos(angle) * scale;
  const s = Math.sin(angle) * scale;
  for (let p = 0; p < count; p++) {
    const x = pts[p * 2],
      y = pts[p * 2 + 1];
    pts[p * 2] = ox + c * x - s * y;
    pts[p * 2 + 1] = oy + s * x + c * y;
  }
}

export interface RigSpec {
  meshes: number;
  /** vertices per mesh side; a mesh has side² vertices. */
  side: number;
  parentWarps: number;
  childWarpsPerParent: number;
  warpGrid: number; // cols = rows
  params: number;
  seed: number;
}

/** A synthetic rig with all buffers preallocated. */
export interface Rig {
  spec: RigSpec;
  totalVertices: number;
  totalTriangles: number;
  params: Float32Array;
  // rotation (root): keyforms 9 × [ox, oy, angle, scale]
  rotForms: Float32Array;
  rotParams: Int32Array; // 2
  pwForms: Float32Array[]; // per parent warp: 9 × gridLen
  pwParams: Int32Array; // 2 per parent warp
  pwWorld: Float32Array[];
  cwForms: Float32Array[];
  cwParams: Int32Array;
  cwParent: Int32Array;
  cwWorld: Float32Array[];
  meshForms: Float32Array[]; // 9 × vertLen (normalized in child warp space)
  meshParams: Int32Array;
  meshParent: Int32Array;
  meshOffset: Int32Array; // float offset into world
  meshVerts: Int32Array;
  meshScratch: Float32Array; // max vertLen
  /** world-space positions of all mesh vertices (canvas px). */
  world: Float32Array;
  uvs: Float32Array;
  indices: Uint32Array;
  meshIndexOffset: Int32Array;
  meshIndexCount: Int32Array;
  // scratch
  idx: Int32Array;
  w: Float32Array;
  rotOut: Float32Array;
  canvasW: number;
  canvasH: number;
}

/** Builds a deterministic synthetic rig of the given size. */
export function buildRig(spec: RigSpec, canvasW = 2000, canvasH = 3000): Rig {
  const r = rng(spec.seed);
  const g = spec.warpGrid;
  const gridPts = (g + 1) * (g + 1);
  const gridLen = gridPts * 2;
  const nCw = spec.parentWarps * spec.childWarpsPerParent;
  const vertsPerMesh = spec.side * spec.side;
  const vertLen = vertsPerMesh * 2;
  const pick = () => Math.floor(r() * spec.params);

  // Rotation root: origin at canvas centre, keyed angle/scale.
  const rotForms = new Float32Array(9 * 4);
  for (let k = 0; k < 9; k++) {
    rotForms[k * 4] = canvasW / 2 + (r() - 0.5) * 20;
    rotForms[k * 4 + 1] = canvasH / 2 + (r() - 0.5) * 20;
    rotForms[k * 4 + 2] = (r() - 0.5) * 0.3;
    rotForms[k * 4 + 3] = 1 + (r() - 0.5) * 0.05;
  }

  // Parent warps: grids in rotation-local px, tiled over the canvas.
  const pwForms: Float32Array[] = [];
  const pwWorld: Float32Array[] = [];
  const pwParams = new Int32Array(spec.parentWarps * 2);
  const tiles = Math.ceil(Math.sqrt(spec.parentWarps));
  for (let p = 0; p < spec.parentWarps; p++) {
    const tx = p % tiles,
      ty = Math.floor(p / tiles);
    const x0 = (tx / tiles) * canvasW - canvasW / 2;
    const y0 = (ty / tiles) * canvasH - canvasH / 2;
    const w = canvasW / tiles,
      h = canvasH / tiles;
    const f = new Float32Array(9 * gridLen);
    for (let k = 0; k < 9; k++) {
      for (let j = 0; j <= g; j++)
        for (let i = 0; i <= g; i++) {
          const o = k * gridLen + (j * (g + 1) + i) * 2;
          f[o] = x0 + (i / g) * w + (k === 4 ? 0 : (r() - 0.5) * w * 0.05);
          f[o + 1] = y0 + (j / g) * h + (k === 4 ? 0 : (r() - 0.5) * h * 0.05);
        }
    }
    pwForms.push(f);
    pwWorld.push(new Float32Array(gridLen));
    pwParams[p * 2] = pick();
    pwParams[p * 2 + 1] = pick();
  }

  // Child warps: grids in parent-warp normalized space.
  const cwForms: Float32Array[] = [];
  const cwWorld: Float32Array[] = [];
  const cwParams = new Int32Array(nCw * 2);
  const cwParent = new Int32Array(nCw);
  for (let c = 0; c < nCw; c++) {
    cwParent[c] = Math.floor(c / spec.childWarpsPerParent);
    const u0 = r() * 0.5,
      v0 = r() * 0.5,
      sz = 0.3 + r() * 0.2;
    const f = new Float32Array(9 * gridLen);
    for (let k = 0; k < 9; k++)
      for (let j = 0; j <= g; j++)
        for (let i = 0; i <= g; i++) {
          const o = k * gridLen + (j * (g + 1) + i) * 2;
          f[o] = u0 + (i / g) * sz + (k === 4 ? 0 : (r() - 0.5) * 0.02);
          f[o + 1] = v0 + (j / g) * sz + (k === 4 ? 0 : (r() - 0.5) * 0.02);
        }
    cwForms.push(f);
    cwWorld.push(new Float32Array(gridLen));
    cwParams[c * 2] = pick();
    cwParams[c * 2 + 1] = pick();
  }

  // Meshes: regular side×side grids in child-warp normalized space.
  const meshForms: Float32Array[] = [];
  const meshParams = new Int32Array(spec.meshes * 2);
  const meshParent = new Int32Array(spec.meshes);
  const meshOffset = new Int32Array(spec.meshes);
  const meshVerts = new Int32Array(spec.meshes);
  const totalVertices = spec.meshes * vertsPerMesh;
  const trisPerMesh = (spec.side - 1) * (spec.side - 1) * 2;
  const indices = new Uint32Array(spec.meshes * trisPerMesh * 3);
  const uvs = new Float32Array(totalVertices * 2);
  const meshIndexOffset = new Int32Array(spec.meshes);
  const meshIndexCount = new Int32Array(spec.meshes);
  let ii = 0;
  for (let m = 0; m < spec.meshes; m++) {
    meshParent[m] = Math.floor(r() * nCw);
    meshParams[m * 2] = pick();
    meshParams[m * 2 + 1] = pick();
    meshOffset[m] = m * vertLen;
    meshVerts[m] = vertsPerMesh;
    const u0 = r() * 0.6,
      v0 = r() * 0.6,
      sz = 0.2 + r() * 0.2;
    const f = new Float32Array(9 * vertLen);
    for (let k = 0; k < 9; k++)
      for (let j = 0; j < spec.side; j++)
        for (let i = 0; i < spec.side; i++) {
          const o = k * vertLen + (j * spec.side + i) * 2;
          const jitter = k === 4 ? 0 : 0.01;
          f[o] = u0 + (i / (spec.side - 1)) * sz + (r() - 0.5) * jitter;
          f[o + 1] = v0 + (j / (spec.side - 1)) * sz + (r() - 0.5) * jitter;
        }
    meshForms.push(f);
    // UVs: each mesh samples a cell of an 8×8 atlas tiling.
    const cell = m % 64;
    const cu = (cell % 8) / 8,
      cv = Math.floor(cell / 8) / 8;
    for (let j = 0; j < spec.side; j++)
      for (let i = 0; i < spec.side; i++) {
        const o = m * vertLen + (j * spec.side + i) * 2;
        uvs[o] = cu + (i / (spec.side - 1)) / 8;
        uvs[o + 1] = cv + (j / (spec.side - 1)) / 8;
      }
    meshIndexOffset[m] = ii;
    const base = m * vertsPerMesh;
    for (let j = 0; j < spec.side - 1; j++)
      for (let i = 0; i < spec.side - 1; i++) {
        const a = base + j * spec.side + i;
        indices[ii++] = a;
        indices[ii++] = a + 1;
        indices[ii++] = a + spec.side;
        indices[ii++] = a + 1;
        indices[ii++] = a + spec.side + 1;
        indices[ii++] = a + spec.side;
      }
    meshIndexCount[m] = ii - meshIndexOffset[m];
  }

  return {
    spec,
    totalVertices,
    totalTriangles: indices.length / 3,
    params: new Float32Array(spec.params),
    rotForms,
    rotParams: new Int32Array([0, 1 % spec.params]),
    pwForms,
    pwParams,
    pwWorld,
    cwForms,
    cwParams,
    cwParent,
    cwWorld,
    meshForms,
    meshParams,
    meshParent,
    meshOffset,
    meshVerts,
    meshScratch: new Float32Array(vertLen),
    world: new Float32Array(totalVertices * 2),
    uvs,
    indices,
    meshIndexOffset,
    meshIndexCount,
    idx: new Int32Array(4),
    w: new Float32Array(4),
    rotOut: new Float32Array(4),
    canvasW,
    canvasH,
  };
}

/**
 * Evaluates the whole rig at the current `rig.params` (every object treated
 * as dirty — the worst case). Allocation-free.
 */
export function evaluateRig(rig: Rig, smooth = true): void {
  const { params, idx, w } = rig;
  const g = rig.spec.warpGrid;
  const gridPts = (g + 1) * (g + 1);
  const gridLen = gridPts * 2;

  cornerWeights(params[rig.rotParams[0]], params[rig.rotParams[1]], smooth, idx, w);
  blend4(rig.rotForms, 4, idx, w, rig.rotOut);
  const ox = rig.rotOut[0],
    oy = rig.rotOut[1],
    ang = rig.rotOut[2],
    sc = rig.rotOut[3];

  for (let p = 0; p < rig.pwForms.length; p++) {
    cornerWeights(params[rig.pwParams[p * 2]], params[rig.pwParams[p * 2 + 1]], smooth, idx, w);
    const out = rig.pwWorld[p];
    blend4(rig.pwForms[p], gridLen, idx, w, out);
    rotatePoints(out, gridPts, ox, oy, ang, sc);
  }

  const scratch = rig.meshScratch;
  for (let c = 0; c < rig.cwForms.length; c++) {
    cornerWeights(params[rig.cwParams[c * 2]], params[rig.cwParams[c * 2 + 1]], smooth, idx, w);
    blend4(rig.cwForms[c], gridLen, idx, w, scratch);
    warpPoints(rig.pwWorld[rig.cwParent[c]], g, g, scratch, 0, rig.cwWorld[c], 0, gridPts);
  }

  for (let m = 0; m < rig.meshForms.length; m++) {
    const n = rig.meshVerts[m];
    cornerWeights(params[rig.meshParams[m * 2]], params[rig.meshParams[m * 2 + 1]], smooth, idx, w);
    blend4(rig.meshForms[m], n * 2, idx, w, scratch);
    warpPoints(rig.cwWorld[rig.meshParent[m]], g, g, scratch, 0, rig.world, rig.meshOffset[m], n);
  }
}

/** Animates parameters deterministically for time t (seconds). */
export function animateParams(rig: Rig, t: number): void {
  for (let i = 0; i < rig.params.length; i++) {
    rig.params[i] = Math.sin(t * (0.7 + i * 0.37) + i);
  }
}

/** Standard benchmark presets. "target" is the M1–M3 acceptance model. */
export const PRESETS: Record<string, RigSpec> = {
  target: { meshes: 150, side: 14, parentWarps: 8, childWarpsPerParent: 4, warpGrid: 5, params: 30, seed: 1 },
  x2: { meshes: 300, side: 14, parentWarps: 16, childWarpsPerParent: 4, warpGrid: 5, params: 40, seed: 2 },
  x4: { meshes: 600, side: 14, parentWarps: 24, childWarpsPerParent: 5, warpGrid: 5, params: 50, seed: 3 },
  x8: { meshes: 600, side: 20, parentWarps: 24, childWarpsPerParent: 5, warpGrid: 5, params: 50, seed: 4 },
};

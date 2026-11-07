# 1. Technical Architecture

Status: proposal, awaiting approval.

## 1.1 Goals that shape the architecture

1. **It is a modelling tool.** The core of the product is the rig data model (meshes, deformers,
   parameters, keyforms) and the evaluator that turns parameter values into deformed geometry.
   The UI edits that data model. The renderer draws whatever the evaluator outputs.
2. **The renderer is separate from the interface** (rule 15.5). The renderer has no knowledge of
   React, of the editor, or even of the document model. It consumes a flat, per-frame
   `FrameData` structure. That also allows headless rendering in a worker for video export.
3. **Logic that can be tested is pure.** Geometry, interpolation, deformer evaluation, physics,
   animation sampling and serialization are pure TypeScript with no DOM dependency, so they run
   in Vitest under Node (rule 15.8).
4. **Built for a 4 GB iPad.** Typed arrays everywhere on the hot path, no per-frame allocation,
   textures held once (on the GPU) with compressed originals stored in IndexedDB, and expensive
   work moved to workers.

## 1.2 Layered overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│ apps/editor  (React PWA)                                                 │
│  Panels (hierarchy, inspector, parameters, timeline, physics)            │
│  Viewport host · tools (mesh/warp/rotation/select) · gesture recognizer  │
│  Overlay renderer (Canvas2D: handles, outlines, grid)                    │
│  Command dispatcher → undo/redo history                                  │
└───────────────┬───────────────────────────────────┬──────────────────────┘
                │ commands (mutations)              │ reads (selectors)
┌───────────────▼───────────────────────────────────▼──────────────────────┐
│ packages/model     Document: normalized entity store, ops, validation    │
└───────┬──────────────────────┬──────────────────────┬────────────────────┘
        │                      │                      │
┌───────▼───────┐  ┌───────────▼─────────┐  ┌─────────▼─────────┐  ┌──────────────┐
│ geometry      │  │ rig (evaluator)     │  │ physics           │  │ animation    │
│ triangulation │  │ keyform interp.     │  │ pendulum chains   │  │ curves,      │
│ contour, CDT  │  │ warp/rotation eval  │  │ fixed-step solver │  │ motion sample│
│ hit-testing   │  │ → FrameData         │  │                   │  │              │
└───────────────┘  └───────────┬─────────┘  └───────────────────┘  └──────────────┘
                               │ FrameData (typed arrays + draw list)
                   ┌───────────▼─────────┐        ┌──────────────────────────────┐
                   │ renderer (WebGL2)   │        │ io: project zip, PSD import, │
                   │ textures, atlases,  │        │ image import, export, Cubism │
                   │ masks, blend modes  │        │ bridge (optional, isolated)  │
                   └─────────────────────┘        └──────────────────────────────┘
                     all of the above built on packages/math (vec2, affine, bezier, easing)
```

Dependency rules are listed in [02-folder-structure.md](02-folder-structure.md) and checked in
CI with dependency-cruiser.

## 1.3 Document model

The document is a **normalized entity store**: one map per entity kind, keyed by stable string
IDs (`nanoid`). There are no nested object graphs, so undo diffs, serialization and React
selectors stay simple. Large numeric data (vertices, UVs, triangle indices, keyform vertex
arrays) is stored as `Float32Array` / `Uint16Array` / `Uint32Array`, not number arrays.

### 1.3.1 Coordinate spaces

| Space | Units | Used by |
|-------|-------|---------|
| Canvas | PSD pixels, origin at top-left, +y down | Base artwork, root-level objects |
| Warp-local | Normalized `(u, v) ∈ [0,1]²` over the warp's grid (extrapolates outside) | Children of a warp deformer |
| Rotation-local | Canvas pixels relative to the rotation origin, before rotation/scale | Children of a rotation deformer |
| View | CSS pixels, from the viewport camera (pan/zoom) | Overlays, hit-testing |

Each object's geometry and keyforms are stored **in the local space of its parent deformer**.
That is how parent deformation propagates to children (requirement 7): a child is defined
relative to its parent, so when the parent moves, the child follows.

### 1.3.2 Entities (abridged TypeScript)

```ts
type Id = string;

interface Part {                 // organizational group (from PSD groups); has opacity and visibility
  id: Id; name: string; parentPartId: Id | null; childOrder: Id[];
  visible: boolean; locked: boolean; keyforms: KeyformSet<{ opacity: number }>;
}

interface ArtMesh {
  id: Id; name: string; partId: Id; parentDeformerId: Id | null;
  textureRef: { layerId: Id };            // source artwork layer → atlas region at runtime
  base: {                                  // the "setup" mesh, in parent-local space
    positions: Float32Array;               // xy pairs
    uvs: Float32Array;                     // in [0,1] of the source layer image
    triangles: Uint16Array;                // or Uint32Array when there are more than 65k vertices
    constraintEdges: Uint32Array;          // user-defined edges kept by the triangulator
  };
  keyforms: KeyformSet<{ positions: Float32Array; opacity: number; drawOrder: number }>;
  blendMode: 'normal' | 'additive' | 'multiply';
  clipMaskIds: Id[]; invertMask: boolean; culling: boolean;
  visible: boolean; locked: boolean;
}

interface WarpDeformer {
  id: Id; name: string; parentDeformerId: Id | null; partId: Id;
  rows: number; cols: number;              // (rows+1)·(cols+1) control points
  keyforms: KeyformSet<{ points: Float32Array; opacity: number }>;
}

interface RotationDeformer {
  id: Id; name: string; parentDeformerId: Id | null; partId: Id;
  keyforms: KeyformSet<{ originX: number; originY: number; angle: number; scale: number; opacity: number }>;
  baseAngle: number;                        // direction of the handle at rest
}

interface Parameter {
  id: Id;                                  // e.g. "ParamAngleX"; unique and user-editable
  name: string; min: number; max: number; default: number;
  group?: string; repeat?: boolean;        // repeat = cyclic, for example a full-turn angle
}

interface KeyformSet<T> {
  bindings: { parameterId: Id; keys: number[]; interpolation: 'linear' | 'smooth' }[];
  forms: T[];                              // row-major over the Cartesian product of keys
}
```

The current parameter values are **not** part of the document. They are session state (they
change at 60 Hz during preview and are not undoable edits). The default values are part of the
document.

## 1.4 Keyforms and interpolation

This follows the well-understood multilinear keyform model used by Cubism-style tools.

An object bound to parameters `p₁…pₙ` with key lists `K₁…Kₙ` has `∏|Kᵢ|` keyforms, one per
grid corner. To evaluate at parameter values `v₁…vₙ`:

1. Per axis `i`, find the segment `[k_j, k_{j+1}]` that contains `vᵢ` (values are clamped to the
   end keys) and compute `t = (vᵢ − k_j)/(k_{j+1} − k_j)`.
2. Apply the axis interpolation: linear `w = t`. Smooth `w = t²(3 − 2t)` (smoothstep), which is
   C¹ at the keys and still exact at them. A Catmull-Rom across neighbouring keys is planned
   later as a third mode.
3. The result is the weighted sum of the `2ⁿ` surrounding corner keyforms with weights
   `∏ (wᵢ or 1−wᵢ)`.

Implementation details:

- Corner weights are computed once per object per frame (n is usually 1–3). Blending is then a
  fused multiply-add over `Float32Array`s into a preallocated output buffer, with no allocation.
- Scalars such as opacity blend the same way. **Draw order** is blended and then rounded, which
  matches artist expectations for keyed draw-order swaps.
- **Editing rule:** keyform edits are allowed only when every parameter bound to the object
  sits exactly on a key. Otherwise the inspector shows "Not on a keyform" and offers
  "Add key at current value". Adding a key along an axis inserts a new slice of keyforms,
  initialized from the currently evaluated state, so adding a key never changes how the model
  looks at that moment.
- **Combinatorial growth:** binding 3 parameters with 3 keys each gives 27 keyforms. The UI shows
  this cost. A later extension (post-M3, flagged in risks) adds **additive blend-shape bindings**,
  which store deltas that are summed instead of multiplied out.
- **Parameter linking:** a parameter can be driven by another through a monotone piecewise-linear
  mapping (for example `EyeROpen ← EyeLOpen`). Links are evaluated in topological order, and
  cycles are rejected when the link is created.

## 1.5 Deformers

### 1.5.1 Warp deformer

A grid of `(rows+1)×(cols+1)` control points. A point `(u, v)` in warp-local space maps through
**bilinear interpolation inside its cell**:

```
cell (i, j) = (⌊u·cols⌋, ⌊v·rows⌋) clamped;  s, t = fractional parts
P = (1−s)(1−t)·C₀₀ + s(1−t)·C₁₀ + (1−s)t·C₀₁ + st·C₁₁
```

Points outside `[0,1]²` extrapolate linearly from the edge cells, so vertices just outside the
grid behave predictably.

**Inverse mapping** is needed to reparent an existing mesh under a warp, which converts its
canvas positions into `(u, v)`. Per candidate cell, solve the bilinear inverse (a quadratic in
`s`) with a Newton-iteration fallback, and pick the solution with `s, t ∈ [0,1]`. Points that are
not found inside any cell fall back to an extrapolation solve. This conversion runs for every
keyform of the reparented object. Unit tests cover it with fold-over and degenerate-cell cases.

"Add/remove control points" is implemented as grid row/column insertion and removal, with the
existing points resampled through the current mapping. The topology stays a regular grid, which
keeps bilinear evaluation well defined. Free-form ("custom") control layouts are listed as an
open question in doc 07.

**Extensibility for free-form control points (owner decision, M0).** The warp deformer is
implemented against a `WarpMapping` interface. Deformer evaluation, reparenting, editing tools
and serialization depend only on this interface, never on "grid":

```ts
interface WarpMapping {
  kind: 'grid' | 'freeform';
  /** control points in parent space (keyformed) */
  pointCount: number;
  /** forward map: local (u,v) → parent space, given current control points */
  map(points: Float32Array, src: Float32Array, dst: Float32Array, n: number): void;
  /** inverse map for reparenting; may be iterative */
  invert(points: Float32Array, src: Float32Array, dst: Float32Array, n: number): void;
  /** per-point local coordinates of children are precomputed per mapping kind */
  bind(childRestLocal: Float32Array): BindingData;
}
```

M3 ships `kind: 'grid'` (bilinear, as above). A later `kind: 'freeform'` (for example mean-value
coordinates over an arbitrary control cage) plugs in without changing the hierarchy walker, the
keyform system or the file format's deformer record. The format stores `mappingKind` and a flat
point list from version 1.

### 1.5.2 Rotation deformer

Keyformed `origin`, `angle`, `scale` and `opacity`. A child point `p` in rotation-local space maps
to `origin + R(angle)·scale·p`.

**Nesting rule (rotation inside a warp):** the origin maps through the parent warp. The effective
rotation also absorbs the parent warp's *local* rotation and scale, estimated from the warp
mapping's Jacobian at the origin (central finite difference over a small Δ along the handle
direction). This is the standard way to make a rotation deformer behave sensibly on a warped
surface. The exact approach gets a design spike and tests in M3.

### 1.5.3 Hierarchy evaluation

Deformers and meshes form a forest by `parentDeformerId`. Each frame:

1. Evaluate parameters: apply UI/animation/physics/auto-generators, then parameter links.
2. Evaluate keyforms for every deformer and mesh into local-space buffers.
3. Walk deformers in topological order (parents first). For warps, transform the local control
   points through the parent chain into canvas space. For rotations, compute the canvas-space
   affine plus its Jacobian correction.
4. Transform mesh vertices through their parent's canvas-space mapping into a single shared
   `Float32Array` of world positions.
5. Accumulate opacity multiplicatively through parent deformers and parts.
6. Produce `FrameData`: world positions, per-drawable opacity, sorted draw order, mask lists and
   dirty ranges.

**Dirty tracking:** each object records which parameters affect it, directly or through its
ancestors. When only `ParamEyeLOpen` changes, only the eye meshes are re-evaluated and re-uploaded
(requirement: "avoid rerendering unrelated objects"). The GPU still redraws the frame, which is
cheap. The geometry work is what dirty tracking skips.

### 1.5.4 Where deformation runs: CPU vs GPU (decision for approval)

Requirement 13 says "use GPU rendering for mesh deformation." The proposal is:

- **Rendering, texture mapping, blending and masking run on the GPU** (WebGL2).
- **Keyform blending and deformer chains run on the CPU** in typed arrays. Reasons: the editor
  needs the deformed positions on the CPU anyway for hit-testing, snapping and handle overlays;
  rigs are small (typically fewer than 30k vertices); and this avoids GPU→CPU readback. Uploads
  are limited to dirty ranges (`bufferSubData`).
- **Measured escalation path:** if profiling on the iPad shows CPU evaluation above budget
  (>4 ms/frame), move steps 2–4 to the GPU with **WebGL2 transform feedback**, with keyform
  arrays in buffers and warp grids in textures. The CPU evaluator stays as the reference
  implementation and test oracle.

**M0 result (iPad run 1):** the target model (29k vertices) evaluates in about 2 ms p95, and 240k vertices in about 4 ms, all at 60 fps (run 2, full screen with batched timing: 0.7 ms and 2.6 ms). CPU deformation is confirmed. GPU deformation is scheduled only for models above about 350k simultaneously deforming vertices, or if real-editor profiling leaves under 4 ms for evaluation. See docs/m0/results-ipad-run1.md.

This choice is stated explicitly rather than taken silently. If GPU evaluation from the start is
a hard requirement, M2/M3 effort increases by roughly 30%.

## 1.6 Rendering engine (`packages/renderer`)

- **WebGL2** with premultiplied alpha and `antialias: false`. Edge quality comes from texture
  padding and an optional MSAA renderbuffer at reduced-quality settings.
- **Textures:** each imported layer is cropped to its non-transparent bounds plus 2–4 px padding,
  then packed into **atlas pages** (maxrects, 2048² or 4096² chosen from `MAX_TEXTURE_SIZE` and
  the quality setting; M0 measured 4096² decode at 117 ms on the iPad, so 4096² is the default). Atlas packing is a derived, rebuildable artifact. The project stores
  per-layer PNGs, and UVs are remapped from layer space to atlas space at load time.
- **Draw path:** one dynamic vertex buffer for world positions, one static buffer for atlas UVs,
  and a static index buffer. Drawables are grouped into draw calls by atlas page, blend mode and
  mask set while respecting draw order (adjacent compatible drawables are merged).
- **Clipping masks:** mask drawables render into an offscreen mask texture (reduced resolution
  when configured). Clipped drawables sample it in the fragment shader, with inverted masks
  supported. Drawables with identical mask sets share one mask render.
- **Blend modes:** normal, additive and multiply in M2, via blend equations on premultiplied
  color. More modes would need framebuffer-fetch emulation (ping-pong) and are deferred.
- **Context loss:** `webglcontextlost` / `restored` are handled. All GPU resources can be rebuilt
  from CPU-side data, with textures re-decoded from stored PNG blobs via `createImageBitmap`.
  iPadOS does drop contexts under memory pressure, so this matters.
- **Quality settings:** render scale (0.5×–1× of devicePixelRatio), atlas resolution
  (full or half), mask resolution, and MSAA on/off.

## 1.7 Editor layer (`apps/editor`)

### 1.7.1 State management

- **Document store:** the `packages/model` store with a monotonically increasing revision counter
  per entity. React components subscribe through selectors (`zustand`-style
  `useSyncExternalStore`) to entity revisions, so a vertex drag re-renders only the inspector
  fields of that mesh, not the hierarchy.
- **Session store (zustand):** selection, active tool, current parameter values, camera, panel
  layout and playback state.
- **The viewport does not render through React.** React mounts the canvas once. A
  `ViewportController` drives `requestAnimationFrame`, pulls the evaluator output and calls the
  renderer. Parameter slider drags write session state and do not re-render the React tree for
  each frame.

### 1.7.2 Commands and undo/redo

Every document mutation is a `Command { apply(doc), revert(doc), merge?(next) }`. Rules:

- Commands store **diffs, not snapshots**. For example, a vertex move stores `indices[]`, `before`
  and `after` as compact typed arrays.
- Continuous gestures (dragging vertices, sliders in edit mode) open a transaction at
  pointer-down, update in place, and commit one command at pointer-up.
- History is capped by estimated byte size (default 64 MB) as well as by count.
- Topology edits (adding or deleting vertices or triangles) are compound commands that update
  every keyform of the mesh:
  - **Inserting a vertex** computes its position in each keyform from the barycentric
    coordinates of the triangle that contains it in the base mesh.
  - **Deleting a vertex** removes it from every keyform and retriangulates locally.

### 1.7.3 Input and gestures

One `GestureRecognizer` on the viewport, built on Pointer Events:

- `pointerType === 'pen'` gives precise tools: select, drag vertex, lasso, place vertex.
- One-finger `touch` is configurable: either the same as pen, or ignored while a pen is active
  (palm rejection). The default is "pen draws, fingers navigate".
- Two fingers pan, pinch-zoom and rotate the view. Three-finger tap is undo and four-finger tap
  is redo, both configurable and with visible toolbar buttons as well.
- Long press (500 ms, movement under 8 px) opens a context menu. No hover-dependent UI exists.
  Everything that is a tooltip on desktop is reachable through a tap or the inspector.
- **Gesture input is accumulated and applied once per frame** from the latest contact positions,
  never per pointer event. M0 showed per-event updates produce transient half-updated camera
  states, because each finger's move arrives as a separate event.
- Palm classification: a touch with contact width ≥ 40 px (iPadOS reports palms up to about
  270 px) or one starting while the Pencil is down is ignored. Threshold to be tuned in M1.
- Hit-testing for vertices, edges and handles runs in view space with a touch radius of 22 CSS px
  for fingers and 10 px for pen (configurable). It is backed by a uniform-grid spatial index
  rebuilt only when geometry changes.

### 1.7.4 Overlays

Selection outlines, mesh wireframes, vertex handles, deformer grids, rotation handles, grid and
guides are drawn on a **Canvas2D overlay** stacked above the WebGL canvas. The overlay is redrawn
only when the camera, selection or affected geometry changes. If wireframe density makes Canvas2D
too slow (more than about 20k edges visible), wireframes move to a WebGL line pass in the
renderer. That is anticipated in the renderer API (`drawWireframe`).

"Onion-skin" aids: a ghost of the base mesh or of the nearest keyform drawn under the current
form, and in the animation workspace, ghost frames at ±N frames.

### 1.7.5 Workspaces

- **Modelling:** hierarchy, inspector, parameters, viewport, mesh/deformer tools.
- **Physics:** group list, pendulum editor (visual chain on canvas plus a graph), preview toggle.
- **Animation:** timeline with tracks and keyframes, curve editor, playback, export.

All workspaces share the same document and evaluator. Animation writes parameter values. It does
not have a separate rig.

## 1.8 Physics (`packages/physics`)

The model is a pendulum chain per physics group, similar in structure to the documented
`physics3.json` concepts so that later import maps naturally:

- **Inputs:** parameters with weight and type (translation X, translation Y, angle), normalized
  from the parameter range to the physics range.
- **Chain:** particles with `radius` (length), `mobility`, `delay`, `acceleration` (weight) and
  `damping`. Gravity and wind are vectors per scene, and wind can be gusty with a seeded noise
  generator.
- **Solver:** fixed timestep (default 1/120 s) with an accumulator and semi-implicit (symplectic)
  Euler integration followed by length-constraint projection (position-based). It is
  **deterministic**: identical inputs and step count give identical outputs, independent of
  render framerate.
- **Outputs:** the angle (or x/y offset) of chosen particles relative to their parent segment,
  scaled and mapped into output parameters.

Tests cover: determinism, framerate independence (30 vs 60 vs 120 Hz render with the same
simulated time gives the same result), energy decay under damping, rest state under gravity,
and length conservation.

## 1.9 Animation (`packages/animation`)

- A **motion** is a set of tracks keyed by target (parameter id, part opacity). Each track holds
  keyframes `{ time, value, interpolation: 'linear' | 'bezier' | 'stepped' | 'inverseStepped',
  handles }`. This is chosen so motion3.json curves import directly.
- The sampler evaluates any time in O(log k) per track by binary search, and in O(1) amortized
  during sequential playback with a cursor cache.
- Playback has speed, loop, and in/out range. Physics runs after the motion sample each frame.
- **Export** renders offline frame by frame with a fixed dt, so physics is reproducible:
  - an image sequence as PNG frames in a zip;
  - video as MP4/H.264 via **WebCodecs `VideoEncoder`** muxed with `mediabunny` where supported,
    falling back to `MediaRecorder` on `canvas.captureStream()` (real-time, lower fidelity).

## 1.10 Persistence and project format

### 1.10.1 Native project file: `.olive` (zip container)

```
project.json            # versioned structured data (schema below)
buffers/geometry.bin    # concatenated little-endian typed arrays
textures/<layerId>.png  # one PNG per artwork layer, cropped, with offset in project.json
thumbnails/cover.png
```

- `project.json` has `formatVersion` (integer), `generator`, and document entities. Typed arrays
  are referenced glTF-style as `{ buffer: 0, byteOffset, length, type: 'f32' }`.
- The schema is defined once with **zod**. TypeScript types are inferred from it, and it
  validates on load with readable error paths.
- **Migrations:** `migrate_N_to_N+1(json)` functions are chained on load. Every released version
  keeps a golden fixture in `fixtures/projects/`, and CI loads all of them.
- The format is documented in `docs/project-format.md`, written in M1 and updated in each
  milestone.

### 1.10.2 Local storage (IndexedDB)

- Object stores: `projects` (metadata), `documents` (latest `project.json` per project),
  `blobs` (content-addressed by SHA-256: PNGs and geometry buffers), `autosave` (rolling
  snapshots).
- **Binary values are stored as `ArrayBuffer`, never `Blob`.** M0 measured WebKit refusing
  `Blob` values in IndexedDB in a third-party context, and `ArrayBuffer` works everywhere.
- **Autosave** runs 2 s after the last committed command, and on `visibilitychange → hidden`.
  Serialization runs in a worker. Unchanged blobs are not rewritten because they are
  content-addressed.
- `navigator.storage.persist()` is requested, and quota is shown via `estimate()`.

### 1.10.3 Files in and out

There is no File System Access API on Safari:

- **Open:** `<input type="file">`, which also lets the user pick from the Files app.
- **Save:** the Web Share API (`navigator.share({ files })` opens the iPad share sheet, which
  includes "Save to Files"), with a fallback to an `<a download>` blob link.

## 1.11 Workers

| Worker | Work |
|--------|------|
| `import.worker` | PSD parse, layer decode, cropping, PNG encode. Transfers `ArrayBuffer`s with zero copy. |
| `mesh.worker` | Automatic mesh generation (contour → simplify → interior sampling → CDT) |
| `io.worker` | Project zip/unzip, hashing, autosave serialization |
| `export.worker` | Offline render (OffscreenCanvas + WebGL2 where available, otherwise main thread) and video encoding |

Worker RPC uses **Comlink**. Workers are module workers created with Vite's `new Worker(new URL(...), { type: 'module' })`.

## 1.12 Automatic mesh generation (algorithm)

1. Threshold the layer alpha at a configurable cutoff, which gives a binary mask.
2. Dilate by a margin of N px so that anti-aliased edges are inside the mesh.
3. Trace contours with marching squares, giving outer polygons and holes.
4. Simplify with Douglas–Peucker at tolerance ε, then resample the boundary at a spacing derived
   from the **density** control.
5. Fill the interior with Poisson-disk or offset-grid points at the same spacing, keeping only
   points inside the polygon.
6. Run constrained Delaunay triangulation (Delaunator + Constrainautor) with the boundary and
   user edges as constraints, then remove triangles outside the polygon or inside holes.
7. Compute UVs from layer-image coordinates.

Manual editing then adds or removes vertices and edges and re-runs CDT with the full constraint
set. Subdivision splits selected triangles at edge midpoints (1→4) and inserts the new vertices
into all keyforms by interpolation.

## 1.13 Live2D compatibility boundary

All Cubism-related code lives in `packages/cubism-bridge`. It is loaded lazily, is optional, and
is not part of the default bundle. It is the only package allowed to touch the Cubism Core. The
native editor has no runtime dependency on it. See [05](05-psd-and-live2d-feasibility.md) for
the licensing analysis.

## 1.14 Testing strategy

| Level | Tooling | Covers |
|-------|---------|--------|
| Unit | Vitest (Node) | math, triangulation, warp forward and inverse mapping, keyform interpolation, physics, curves, serialization and migrations |
| Property-based | fast-check | e.g. "a keyform evaluated at a key equals that keyform", "inverse(warp(p)) ≈ p", "save → load → save gives identical bytes" |
| Golden / snapshot | Vitest | fixture projects evaluated at fixed parameters produce fixed vertex buffers |
| Rendering | Playwright (Chromium + WebKit) | render fixture projects and compare pixels against references within a tolerance |
| E2E | Playwright with touch emulation | import a PSD, create a mesh, drag a vertex, undo, save, reload |
| Device | Manual checklist on iPad 10th gen | per-milestone acceptance script (doc 06), with FPS and memory recorded |

Playwright WebKit is close to Safari but not the same engine build. Real-device checks remain
mandatory for each milestone sign-off.

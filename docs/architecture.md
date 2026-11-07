# Architecture

Move2D is a Swift package of small modules plus a thin SwiftUI app. Dependencies
only point downwards:

```
          App (SwiftUI, UIKit input, MTKView)
                         │
                     M2DEditor ──────────────┐
        ┌──────────┬─────┴──────┬──────────┐ │
   M2DProject   M2DExport    M2DMetal   M2DRender
        │           │            │          │
   M2DPSD   M2DAnimation  M2DPhysics        │
        └───────┬───┴────────────┴──────────┘
              M2DRig
                │
             M2DCore
```

* **Rendering engine** — `M2DRender` (render list + CPU rasteriser) and `M2DMetal`.
* **Rigging system** — `M2DRig`.
* **Animation system** — `M2DAnimation`, `M2DPhysics`.
* **Interface** — `App/`, driving `M2DEditor`.

A game only needs `M2DRuntime` (Core + Rig + Animation + Physics + Render) and an
`.m2rt` file.

## Data model (`M2DRig`)

* `RigModel` — canvas size, `parts`, `meshes`, `deformers`, `parameters`, `textures`
  and `rootChildren` (top-level hierarchy, front-most first).
* `Part` — an organisational group (from a PSD group): children, visibility, opacity, lock.
* `ArtMesh` — a textured triangle mesh: rest vertices in canvas pixels, UVs into
  its own texture, `textureRect` (where the texture sits on the canvas), blend
  mode, clipping masks, a `deformerID` (deformation parent) and keyforms.
* `Deformer` — `warp` (lattice of (columns+1)×(rows+1) points over a rectangle) or
  `rotation` (pivot, angle, scale). Each has a `parentID`, giving a tree that is
  independent of the layer hierarchy, exactly like rigging needs (an eye's meshes
  can sit in the "Eye L" layer group yet be deformed by "Head Warp").
* `Parameter` — id, name, min/max/default, group, cyclic flag.

### Keyforms

Every mesh and deformer stores a `KeyformGrid<Form>`:

* `bindings`: the parameters it reacts to, each with sorted key values;
* `forms`: one form per combination of keys (cartesian product, first binding
  varies fastest).

Evaluation finds, for every bound parameter, the segment `[k_i, k_i+1]` and its
fraction `t`, then blends the 2ⁿ surrounding forms with multilinear weights.
Mesh forms are per-vertex *offsets* from the rest mesh (plus opacity and draw
order); warp forms are absolute lattice points; rotation forms are pivot, angle,
scale and opacity.

Editing a shape is only allowed when every bound parameter sits exactly on a key,
so the user always edits a real keyform; adding a key interpolates the new forms
from existing ones, so nothing jumps.

### Evaluation pipeline

```
parameters ─▶ animation (clip layers) ─▶ physics (reads inputs, writes outputs)
           ─▶ RigEvaluator: blend keyforms ─▶ map vertices through deformer chain
           ─▶ RigPose (positions, opacity, draw order) ─▶ RenderListBuilder ─▶ Metal / CPU
```

Deformers are composed in rest space: a deformer is a function from its input
space (its parent's rest space) to its parent's input space. A vertex is mapped
by its own deformer, then each ancestor in turn. Warp mapping is bilinear inside
the lattice and extrapolates linearly outside it. Rotation mapping is
`origin + R(angle)·scale·(p − restOrigin)`.

When the user drags a deformed vertex on screen, the canvas delta is converted to
the object's input space with the inverse Jacobian of the deformer chain at that
point (`RigEvaluator.canvasDeltaToLocal`), so editing feels direct at any depth
of nesting.

Draw order: meshes sort by keyformed draw order (default 500), ties broken by
the layer hierarchy, so the PSD stacking is preserved until changed.

Deformation runs on the CPU — it is a few thousand multiply-adds per mesh,
deterministic, and shared by the editor, exporters and runtime. Metal does the
compositing (premultiplied alpha, normal/additive/multiply/screen blending,
stencil clipping masks, mipmapped textures).

## Physics

Each `PhysicsGroup` is a pendulum chain anchored at a point that moves with its
inputs (translation from e.g. Angle X, tilt from Angle Z). The chain is
integrated with Verlet steps at a fixed 120 Hz with damping, a spring towards
the rest direction, a "mobility" term for follow-through, and distance
constraints. Outputs convert the angle of a chosen segment, relative to the
anchor frame, into a parameter value — which then drives ordinary keyforms
(typically a sway warp).

## Editor (`M2DEditor`)

`EditorSession` is an `@Observable` class holding the `ProjectBundle` (project +
textures), selection, tools, parameter values, playhead and the evaluated pose.
All mutations go through `perform(name) { bundle in … }`, which records a
snapshot for undo (value types make snapshots cheap and safe). Drags are grouped
with `beginGesture`/`endGesture`. The app mirrors each step into the system
`UndoManager`, which gives ⌘Z, three-finger undo and document autosave.

## Formats

See [project-format.md](project-format.md) and [runtime-format.md](runtime-format.md).

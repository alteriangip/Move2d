# 6. Milestone Plan and Development Roadmap

Rules applied (from the brief, §15):

- A milestone is complete only when **all** of its acceptance tests pass: the automated suite in
  CI, plus the manual iPad checklist with results recorded in `docs/acceptance/M<n>.md`.
- No milestone starts before the previous one is signed off.
- Features not yet implemented are **absent or visibly disabled with a label** ("Available in
  M3"). The UI never shows buttons that do nothing.
- Each milestone keeps every earlier test green.

Effort estimates assume one full-time developer working with AI assistance. They are indicative
only.

---

## Milestone 0: Platform spike (≈1 week, before M1; throwaway code)

Purpose: replace the **[verify]** assumptions in doc 04 with measurements before committing to
the architecture.

- A WebGL2 stress page on the iPad: `MAX_TEXTURE_SIZE`, the texture allocation level that causes
  a crash, and context-loss behaviour.
- Pointer-event logger: pen vs touch, pressure and tilt for both Pencil models if available,
  coalesced events, and Scribble interference.
- PSD benchmark: ag-psd vs @webtoon/psd on fixture files, measuring peak memory and time on the
  iPad.
- Storage: quota estimate, `persist()` result, and eviction behaviour as a PWA vs a tab.
- WebCodecs H.264 encoder configurations that are supported.

Output: `docs/adr/0001-platform-measurements.md`, with doc 04 updated.

---

## Milestone 1: Foundation (≈4–5 weeks)

**Status: implemented** in `app/` (owner asked to stop M0 testing and build). Deviations from
the plan, stated plainly:

- A single Vite app with `src/engine/*` (math, model, render, io) and `src/editor/*` folders,
  rather than a pnpm multi-package workspace. The renderer still has no React or editor imports;
  enforcing this in CI is a follow-up.
- Layers are drawn as one texture each. Atlas packing arrives with meshes in M2.
- Reordering uses Move up/down, Group, and Move into/out of group actions (no drag-and-drop yet).
- The installable PWA is the GitHub Pages build (manual workflow run). The claude.ai-hosted
  build runs in a frame, so it cannot be installed to the Home Screen.

Automated: 17 unit tests (document ops, undo/redo, .olive round trip and validation, import
mapping, view transforms) and a 21-step end-to-end script (`app/scripts/e2e.mjs`): PSD import →
hierarchy → tap select → Pencil drag → undo/redo → opacity → rename → group → pinch zoom →
autosave and reload → export and re-import → portrait.

**Deliverables**

- pnpm monorepo, strict TypeScript, CI (lint, typecheck, unit, e2e, dependency rules, licence
  audit, build).
- PWA: manifest, icons, service worker, offline start, update prompt, HTTPS preview deploys.
- Dark, touch-first shell: resizable panels (separate layouts for landscape and portrait),
  toolbar, workspace tabs, touch-sized controls (≥44 pt), long-press context menus.
- `packages/math`, `packages/model` (schema, store, commands), with undo/redo working from day one.
- WebGL2 renderer v1: textured quads per layer, atlas packing, premultiplied alpha, context-loss
  restore, render-scale setting.
- Viewport: two-finger pan, pinch zoom and rotate; fit-to-screen; grid; selection outline.
- Import: PNG, JPEG, layered PSD in a worker, with the import preview dialog and warnings.
- Hierarchy panel: Parts and layers; rename, reorder (drag), group, visibility, lock, delete,
  and reparent between Parts.
- Inspector v1: name, visibility, opacity, draw order, layer bounds.
- Persistence: IndexedDB project library, autosave, `.olive` export via Share/Download, `.olive`
  import, format v1 documented in `docs/project-format.md`.
- Diagnostics panel (FPS, GPU memory estimate, log export).

**Acceptance tests**

- *Automated:* model ops and undo/redo round trips; serialization round trip
  (`save(load(save(d))) === save(d)` byte-identical); schema rejects malformed files with useful
  errors; PSD fixture imports with the expected tree, names, order, opacity and visibility;
  E2E: import PSD → rename layer → reorder → hide → undo ×3 → export → re-import gives the
  same structure.
- *iPad:* install as PWA, works in airplane mode; import a 150-layer PSD without a crash; pan
  and zoom at 60 fps; force-close the app and reopen, and the autosaved project is intact;
  the exported file is saved to the Files app and re-opened.

---

## Milestone 2: Mesh editor (≈5–6 weeks)

**Deliverables**

- ArtMesh entity from a layer, starting as a quad.
- Automatic mesh generation (contour → simplify → interior sampling → CDT) in a worker, with
  density, margin and alpha-threshold controls and a live preview.
- Manual editing: add or delete vertices, add or delete edges (constraints), retriangulate,
  select (tap, lasso, add/subtract), multi-select move/scale/rotate, subdivide selection.
- Texture mapping: UVs from layer space; atlas remapping; rendering of real triangle meshes.
- Base mesh deformation: move vertices to change the base form; textures follow through UVs.
- Overlays: wireframe, vertex handles, mesh visibility toggles, onion-skin of the original.
- Clipping masks (mask texture pass), blend modes (normal, additive, multiply), drawable
  opacity, and draw-order editing in the inspector.
- Spatial-index hit-testing with separate touch and pen radii.

**Acceptance tests**

- *Automated:* triangulation is valid (no overlapping triangles, all constraints present, every
  boundary vertex used) via property tests over random polygons; contour tracing on fixture
  alphas; subdivision preserves area; inserting a vertex preserves the shape (barycentric);
  UVs map the texture exactly (render test against a reference image); clipping render test.
- *iPad:* auto-mesh a hair layer in under 1 s; drag vertices with the Pencil precisely while
  palm rejection works; finger navigation never moves vertices; undo every mesh operation.

---

## Milestone 3: Rigging (≈7–8 weeks; the core of the product)

**Deliverables**

- Parameters: create, edit, delete, group; min/max/default; standard presets (ParamAngleX/Y/Z,
  EyeL/ROpen, MouthOpenY, MouthForm, BodyAngleX/Y, Breath) available as a template, not as
  hard-coded values.
- Keyforms: bind an object to 1–3 parameters, add or remove keys, edit at keys (vertices,
  opacity, draw order, deformer points/angle), "not on keyform" guard, linear and smooth
  interpolation.
- Warp deformer: create with rows/cols, insert/remove rows/columns, move points, nest, and
  assign multiple meshes. Reparenting uses the inverse mapping.
- Rotation deformer: origin, angle, scale; handle UI; angle range on parameter keys; nesting,
  including inside warps.
- Hierarchy evaluation with dirty tracking, and parent→child propagation.
- Parameter linking. Auto generators for eye blink and breath.
- Parameter panel with large touch sliders, and a 2D pad for paired parameters (AngleX/Y).

**Acceptance tests**

- *Automated:* evaluation at each key reproduces that keyform exactly; multilinear interpolation
  against hand-computed cases; smoothstep is continuous; warp forward/inverse round trip
  (`|inv(f(p)) − p| < 1e-4`) including extrapolation; rotation nesting cases; adding a key does
  not change the current pose; golden evaluation of fixture rigs; no per-frame allocations
  (allocation-counting test harness).
- *iPad:* rig a fixture character's head turn (AngleX ±30) with eyes and mouth; 60 fps while
  scrubbing parameters on the 30k-vertex target model.

---

## Milestone 4: Physics (≈3–4 weeks)

**Deliverables**

- Physics groups with inputs (parameter, type, weight), a pendulum chain (length, weight,
  mobility, delay, damping), outputs (particle, type, scale), and gravity and wind
  (with a seeded gust option).
- Visual pendulum editor: chain drawn on the canvas, with draggable particles to set lengths.
- Real-time preview: drag the head angle and watch the hair parameters respond. Reset button.
  Fixed-step solver.

**Acceptance tests**

- *Automated:* determinism (same seed and inputs give bit-identical outputs); render-rate
  independence; damping energy decay; rest state under gravity; length conservation within
  tolerance; serialization round trip.
- *iPad:* hair and earring physics on the fixture model at 60 fps; the same recorded input gives
  the same motion when replayed.

---

## Milestone 5: Animation (≈4–5 weeks)

**Deliverables**

- Timeline: tracks per parameter or part opacity, keyframes (add, move, delete, multi-select),
  interpolation types (linear, bezier with handles, stepped, inverse stepped), and a curve editor.
- Playback: play/pause, speed (0.25×–2×), loop, in/out range, scrubbing; physics applied during
  playback.
- Onion-skin ghost frames.
- Export: PNG sequence (zip) and MP4 via WebCodecs where supported, with a real-time
  MediaRecorder fallback clearly labelled. Transparent-background PNG option.

**Acceptance tests**

- *Automated:* curve sampling against reference values (bezier via de Casteljau / Newton solving
  for t); stepped semantics; loop wraparound; motion serialization; an offline export of N frames
  gives N deterministic frames (hash comparison).
- *iPad:* export a 10 s 1080p clip and confirm it plays in the Photos/Files app.

---

## Milestone 6: Compatibility (≈3–4 weeks, gated by the licensing decision)

**Deliverables**

- Licensing decision recorded (ADR), and Live2D contacted if Cubism model import will be released.
- `model3.json` reader, `motion3.json` → native motions, `physics3.json` → native physics
  (documented as an approximate mapping).
- `cubism-bridge` (behind a flag): load `.moc3` through a locally supplied Core, preview using our
  renderer, and a "baked import" into an editable mesh-only project.
- Interoperability report: Inochi2D or other open formats, and the OpenLive runtime player.
- Documentation that **no `.moc3` export exists**, and why.

**Acceptance tests**

- *Automated:* JSON readers against sample files the project is licensed to use (for example
  Live2D sample models, *subject to their licence terms*); motion import produces identical curve
  samples.
- *Manual:* side-by-side preview against the official Cubism Viewer for a sample model.

---

## Cross-cutting backlog (scheduled after M3 when the core is proven)

- Additive blend-shape bindings, to avoid keyform explosion.
- Catmull-Rom ("natural") interpolation.
- GPU deformation via transform feedback, only if profiling requires it.
- Microphone lip-sync for mouth parameters.
- Compressed textures (ASTC) if supported.
- OpenLive runtime player package.
- Localization.

## Roadmap maintenance

This file is the living roadmap. Each milestone sign-off updates it with the actual dates,
deviations and the link to `docs/acceptance/M<n>.md`.

# OpenLive

A touch-first 2D character **rigging and animation editor** for iPadOS (PWA), in the spirit of
Live2D Cubism Editor: it takes layered illustrations (PSD) and turns them into parameter-driven,
deformable, physics-enabled characters.

OpenLive is **not** a Live2D viewer and **not** a frame-by-frame animation app. It has its own
implementation, its own project format and its own architecture. It contains no proprietary
Live2D code and does not reverse-engineer proprietary formats.

## Status

**Milestone 1 (Foundation) is usable.** The editor lives in [`app/`](app).

What works today, on iPad and desktop:

- Import **layered PSD/PSB** (names, order, groups, visibility, opacity, blend modes, clipping
  flag; raster masks baked into alpha; unsupported features listed as notices), plus PNG/JPEG.
  Import preview lets you leave layers out. Each layer stays separate and editable.
- WebGL2 canvas: **two-finger pan / pinch-zoom / rotate**, one-finger pan, **Apple Pencil**
  selects and drags layers, palm contacts are ignored, pixel-accurate tap selection.
- Layers panel: rename, reorder, group / ungroup, move into and out of groups, hide, lock,
  delete; long-press for the action menu. Inspector: name, visibility, lock, opacity, position,
  blend mode.
- Undo/redo for every edit. **Autosave on the device** (IndexedDB), project list, and
  **export/import of native `.olive` project files** (format v1, see
  [docs/project-format.md](docs/project-format.md)).
- Portrait and landscape layouts; dark theme; touch targets ≥ 44 pt.

Not yet implemented (next milestones): meshes and triangulation (M2), drawing clipping masks
(M2), deformers, parameters and keyforms (M3), physics (M4), animation (M5), Live2D interop (M6).
[Feature status register](docs/feature-status.md).

Milestone 0 measurements on the target iPad are in [docs/m0](docs/m0).

Planning documents:

| # | Document | Contents |
|---|----------|----------|
| 1 | [Technical architecture](docs/01-architecture.md) | Layers, data model, evaluation pipeline, rendering, editing, persistence |
| 2 | [Project folder structure](docs/02-folder-structure.md) | Monorepo layout and dependency rules between packages |
| 3 | [Dependencies](docs/03-dependencies.md) | Every proposed library, why it is needed, and alternatives |
| 4 | [iPad Safari compatibility](docs/04-ipad-safari-compatibility.md) | Platform capabilities, limits and mitigations for iPad 10th gen |
| 5 | [PSD & Live2D feasibility](docs/05-psd-and-live2d-feasibility.md) | What PSD import can and cannot preserve; what Live2D interop is legally and technically possible |
| 6 | [Milestone plan / roadmap](docs/06-roadmap.md) | Milestones 1–6 with deliverables and acceptance tests |
| 7 | [Risks & open questions](docs/07-risks-and-questions.md) | Technical risks, mitigations, and decisions needed from the project owner |

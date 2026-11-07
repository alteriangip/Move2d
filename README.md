# OpenLive

A touch-first 2D character **rigging and animation editor** for iPadOS (PWA), in the spirit of
Live2D Cubism Editor: it takes layered illustrations (PSD) and turns them into parameter-driven,
deformable, physics-enabled characters.

OpenLive is **not** a Live2D viewer and **not** a frame-by-frame animation app. It has its own
implementation, its own project format and its own architecture. It contains no proprietary
Live2D code and does not reverse-engineer proprietary formats.

## Status

**Phase: planning. Awaiting approval before implementation starts.**

No application code exists yet. The planning documents are:

| # | Document | Contents |
|---|----------|----------|
| 1 | [Technical architecture](docs/01-architecture.md) | Layers, data model, evaluation pipeline, rendering, editing, persistence |
| 2 | [Project folder structure](docs/02-folder-structure.md) | Monorepo layout and dependency rules between packages |
| 3 | [Dependencies](docs/03-dependencies.md) | Every proposed library, why it is needed, and alternatives |
| 4 | [iPad Safari compatibility](docs/04-ipad-safari-compatibility.md) | Platform capabilities, limits and mitigations for iPad 10th gen |
| 5 | [PSD & Live2D feasibility](docs/05-psd-and-live2d-feasibility.md) | What PSD import can and cannot preserve; what Live2D interop is legally and technically possible |
| 6 | [Milestone plan / roadmap](docs/06-roadmap.md) | Milestones 1–6 with deliverables and acceptance tests |
| 7 | [Risks & open questions](docs/07-risks-and-questions.md) | Technical risks, mitigations, and decisions needed from the project owner |

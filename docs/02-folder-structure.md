# 2. Proposed Project Folder Structure

The repository is a **pnpm workspace monorepo**. Package boundaries enforce the separation
between the engine, the data model and the UI. A package can only import what its
`package.json` declares, and dependency-cruiser checks the direction of imports in CI.

```
openlive/                         (this repository)
├─ apps/
│  └─ editor/                     React PWA: the only package that knows about React or the DOM UI
│     ├─ index.html
│     ├─ public/                  icons, manifest assets, splash screens
│     ├─ src/
│     │  ├─ main.tsx              bootstrap, service-worker registration
│     │  ├─ app/                  shell layout, workspace switching, theme tokens
│     │  ├─ panels/
│     │  │  ├─ hierarchy/         tree view (virtualized), drag-reorder, context menus
│     │  │  ├─ inspector/         per-entity property editors
│     │  │  ├─ parameters/        parameter list, sliders, key editor, link editor
│     │  │  ├─ timeline/          tracks, keyframes, curve editor, playback
│     │  │  ├─ physics/           group list, pendulum editor
│     │  │  └─ import/            PSD import preview and layer mapping dialog
│     │  ├─ viewport/
│     │  │  ├─ ViewportController.ts   rAF loop: session → evaluator → renderer
│     │  │  ├─ camera.ts               pan/zoom/rotate view transform
│     │  │  ├─ overlay/                Canvas2D overlay drawing (handles, grids, outlines)
│     │  │  └─ hit-test.ts             spatial index plus picking
│     │  ├─ input/                GestureRecognizer, pen/touch policy, long-press
│     │  ├─ tools/                select, mesh-edit, auto-mesh, warp, rotation, keyform-edit
│     │  ├─ commands/             Command implementations plus history/transactions
│     │  ├─ state/                zustand session store (selection, tool, params, layout)
│     │  ├─ storage/              IndexedDB repository, autosave scheduler
│     │  ├─ workers/              worker entry points (import, mesh, io, export)
│     │  ├─ components/           reusable touch-sized UI primitives (Button, Slider, NumberField…)
│     │  └─ diagnostics/          on-device FPS/memory/GPU/log panel (no Mac Web Inspector)
│     ├─ vite.config.ts
│     └─ tests/                   component tests
│
├─ packages/
│  ├─ math/          vec2, affine2d, bezier, easing, numeric solvers. No dependencies.
│  ├─ geometry/      contour tracing, simplification, sampling, CDT wrapper, subdivision,
│  │                 barycentric utilities, point-in-polygon, spatial grid
│  ├─ model/         zod schema, entity types, Document store, revisioned ops, validation
│  ├─ rig/           keyform interpolation, warp/rotation evaluation, hierarchy walk,
│  │                 parameter links, dirty tracking → FrameData
│  ├─ physics/       pendulum solver, input/output mapping, fixed-step runner
│  ├─ animation/     curves, motion tracks, sampler, auto-blink/breath generators
│  ├─ renderer/      WebGL2 renderer consuming FrameData; atlas packing; masks; blends.
│  │                 Depends only on math. Knows nothing about model/editor.
│  ├─ io/            project zip read/write + migrations, PSD import adapter,
│  │                 PNG/JPEG import, image-sequence/video export helpers
│  └─ cubism-bridge/ OPTIONAL. Lazy-loaded. Adapter around the official Cubism Core
│                    (user/maintainer supplied, never committed). Isolated licence boundary.
│
├─ fixtures/
│  ├─ psd/           test PSDs created for this project (own artwork; licence documented)
│  ├─ projects/      golden .olive files for every released formatVersion
│  └─ renders/       reference images for render tests
├─ tests/
│  └─ e2e/           Playwright specs (Chromium + WebKit, touch emulation)
├─ docs/
│  ├─ 01..07-*.md    planning docs (this set)
│  ├─ project-format.md   (written in M1, versioned with the format)
│  └─ adr/           architecture decision records, one file per decision
├─ .github/workflows/ci.yml   lint, typecheck, unit, e2e, dependency rules, build
├─ pnpm-workspace.yaml
├─ tsconfig.base.json         strict mode, project references
└─ .dependency-cruiser.cjs
```

## 2.1 Allowed dependency directions

```
math ← geometry ← model ← rig ← { physics, animation }
math ← renderer                      (renderer never imports model/rig)
model, rig, geometry ← io
everything ← apps/editor
cubism-bridge → io, model            (nothing imports cubism-bridge statically)
```

Packages other than `apps/editor`, `io` and `renderer` may not use DOM APIs. Their tsconfig
uses `lib: ["ES2022"]` without `DOM`, so accidental DOM use fails type-checking.

## 2.2 Naming conventions

- Files use kebab-case. React components use PascalCase.
- Each package exposes a single `src/index.ts`. Deep imports are forbidden.
- Every public function has a TSDoc comment (rule 15.6), checked by the eslint-plugin-tsdoc
  lint rule.

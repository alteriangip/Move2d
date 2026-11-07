# 3. Dependency List

Principles:

- Use a mature, maintained library where the problem is well solved and not central to the
  product: zip, IndexedDB, PSD decoding, Delaunay triangulation, UI primitives.
- **Write our own code** where the code *is* the product: the keyform evaluator, deformers,
  physics, renderer, mesh editing operations, gesture handling.
- Pin exact versions in a lockfile. Run a licence audit (`license-checker`) in CI, and allow only
  permissive licences (MIT/ISC/BSD/Apache-2.0, and MPL-2.0 for unmodified files).
- No game engine. PixiJS and Three.js were considered and rejected: they would hide the mesh and
  deformer pipeline we must build ourselves and add bundle weight for features we don't use.

Licences marked † are to be confirmed during the M1 licence audit.

## 3.1 Runtime dependencies

| Package | Purpose | Why this one | Licence | Alternatives considered |
|---------|---------|--------------|---------|-------------------------|
| `react`, `react-dom` | UI framework (required by the brief) | Required; widespread knowledge; concurrent rendering keeps panels responsive | MIT | — |
| `zustand` | Session/UI state store | Tiny, selector-based subscriptions, works outside React (needed by the viewport loop) | MIT | Redux Toolkit (heavier), Jotai |
| `ag-psd` | PSD/PSB reading | Most complete maintained JS PSD reader: layer tree, groups, opacity, visibility, blend modes, clipping, masks; can return raw `ImageData` without a canvas (works in workers) | MIT | `@webtoon/psd` (**rejected in M0**: failed on a real-world PSD, last release 2023), `psd.js` (unmaintained) |
| `delaunator` | Fast 2D Delaunay triangulation | Robust, fast, widely used, maintained by Mapbox | ISC | `cdt2d` (unmaintained), `poly2tri` (fragile on duplicate points) |
| `@kninnug/constrainautor` | Constrained edges on top of Delaunator | Adds the boundary/user-edge constraints needed for mesh editing | ISC† | `earcut` (no interior Steiner points, poor triangle quality) |
| `fflate` | Zip read/write for `.olive` and PNG-sequence export | Fastest pure-JS deflate; streaming; worker-friendly; small | MIT | JSZip (slower, larger) |
| `idb` | IndexedDB promise wrapper | Thin, typed, no abstraction lock-in | ISC | Dexie (heavier; querying not needed) |
| `zod` | Project schema definition and validation; type inference | One source of truth for types and runtime validation of untrusted files | MIT | valibot (smaller; acceptable swap) |
| `comlink` | Worker RPC | Removes postMessage boilerplate, supports transferables | Apache-2.0 | hand-written message protocol |
| `nanoid` | Stable entity IDs | Small, URL-safe, collision-resistant | MIT | `crypto.randomUUID` (fine too; nanoid is shorter in JSON) |
| `maxrects-packer` | Texture atlas packing | Proven MaxRects bin packing with padding support | MIT | own shelf packer (worse packing) |
| `mediabunny` | MP4/WebM muxing for WebCodecs output | Successor to `mp4-muxer`/`webm-muxer` by the same author; browser-native, no ffmpeg.wasm | MPL-2.0† | `mp4-muxer` (MIT, archived in favour of mediabunny), `ffmpeg.wasm` (≈30 MB, too heavy for iPad) |
| `@radix-ui/react-*` | Accessible primitives: context menu (right-click **and long-press**), popover, dialog, dropdown, tabs | Unstyled, so it fits our touch-sized dark theme; handles focus and ARIA | MIT | Headless UI, React Aria |
| `react-resizable-panels` | Adjustable/collapsible panel layout, persisted per orientation | Pointer-event based, so it works with touch | MIT | own splitter |
| `@dnd-kit/core` + `sortable` | Hierarchy reordering and reparenting by drag | Touch and pointer sensors with activation delay, which avoids conflicts with scrolling | MIT | react-dnd (HTML5 backend does not support touch) |
| `@tanstack/react-virtual` | Virtualized hierarchy/parameter lists | Models can have several hundred nodes | MIT | react-window |
| Live2D **Cubism Core for Web** + **Cubism Web Framework** | *Optional*, M6 only, inside `cubism-bridge` | The only legitimate way to load `.moc3` | Proprietary (Core) / Live2D Open Software License (Framework) | none; see doc 05. **Not bundled** by default |

Deliberately **not** used:

- `gl-matrix`: we only need 2D affine math, so `packages/math` is our own small, tested module.
- `@use-gesture`: viewport gestures need pen/touch arbitration that it does not model.
- Immer: it does not draft typed arrays efficiently. The command system uses explicit diffs
  instead.

## 3.2 Development dependencies

| Package | Purpose |
|---------|---------|
| `typescript` (strict) | Language |
| `vite`, `@vitejs/plugin-react` | Dev server and build; native module workers; fast HMR |
| `vite-plugin-pwa` (Workbox) | Service worker, precache manifest, offline support, update prompt |
| `vitest` | Unit and golden tests (Node environment for pure packages, jsdom for components) |
| `fast-check` | Property-based tests for geometry, interpolation and serialization |
| `@playwright/test` | E2E and render tests in Chromium and **WebKit**, with touch emulation |
| `eslint`, `typescript-eslint`, `eslint-plugin-react-hooks`, `eslint-plugin-tsdoc` | Linting and documentation enforcement |
| `prettier` | Formatting |
| `dependency-cruiser` | Enforces the package dependency directions from doc 02 |
| `license-checker` (or `license-checker-rseidelsohn`) | CI licence audit |
| `eruda` (dev/diagnostic builds only) | On-device console and network inspector on iPad without a Mac |
| `@vitejs/plugin-basic-ssl` or `mkcert` | HTTPS dev server, required for service workers and some APIs when testing on an iPad over LAN |

## 3.3 Browser APIs relied on (no library)

WebGL2, Pointer Events, IndexedDB, Web Workers (module), `createImageBitmap`, OffscreenCanvas,
WebCodecs `VideoEncoder` (optional path), `MediaRecorder` (fallback), Web Share API (Level 2,
files), `navigator.storage.persist/estimate`, Web Audio (later: lip-sync from microphone),
`CompressionStream` (optional). Each API is feature-detected, and its absence produces a visible
explanation, never a silent no-op (rule 15.1).

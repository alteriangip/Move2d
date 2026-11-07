# 4. iPad Safari Compatibility Assessment

Reference device: **iPad (10th generation)**, A14 Bionic, 4 GB RAM, 2360×1640 Liquid Retina at
264 ppi, 60 Hz. It shipped with iPadOS 16.1 and supports current iPadOS releases.

**Proposed minimum: iPadOS 17.** That release brings WebGL in OffscreenCanvas,
`navigator.storage.persist()`, and larger storage quotas. Desktop Chrome, Edge, Firefox and
Safari are secondary targets, and Android Chrome is best-effort.

Items marked **[verify]** must be confirmed on the physical device during the M1 platform spike.
Do not rely on them until they are confirmed.

## 4.1 Capability matrix

| Capability | Status on iPadOS 17+ Safari | Impact / plan |
|------------|-----------------------------|---------------|
| **WebGL2** | Supported (since Safari 15), implemented over Metal via ANGLE | Core renderer target. Query `MAX_TEXTURE_SIZE` at runtime (A14 is expected to report 16384) **[verify]** |
| WebGL2 transform feedback | Part of WebGL2 | Available as a GPU-deformation escalation path |
| Float textures / `EXT_color_buffer_float` | Extension-dependent **[verify]** | Not required. Masks use RGBA8 |
| **WebGL context loss** | Happens under memory pressure and on backgrounding | Mandatory restore path (doc 01 §1.6) |
| **Pointer Events** | Supported. `pointerType: 'pen'/'touch'`, `pressure`, `tiltX/Y` | Basis of all input |
| `getCoalescedEvents()` / `getPredictedEvents()` | **[verify]**; support has varied by version | Feature-detect. Vertex dragging works without them |
| Apple Pencil pressure | **1st-gen Pencil: yes. Apple Pencil (USB-C): no pressure.** Both are the Pencils compatible with iPad 10th gen | **No feature may require pressure.** Pressure is only an optional modifier, for example soft-selection falloff |
| Apple Pencil hover | Not available on iPad 10th gen (it needs M2+ iPad Pro, or newer devices) | Don't design for hover. This is consistent with the no-hover rule |
| Pencil double-tap / squeeze | Not exposed to web content | Use on-screen modifier buttons instead |
| Multi-touch gestures | Pointer Events give per-finger tracking | Own recognizer. Disable Safari's page gestures with `touch-action: none` and `gesturestart` preventDefault |
| Page zoom / double-tap zoom / text callouts | Safari defaults interfere | `touch-action: none` on the canvas, `-webkit-touch-callout: none`, `user-select: none` on chrome, and the viewport meta tag |
| **Scribble** (Pencil handwriting in text fields) | Can capture Pencil input near inputs | Keep text inputs out of the canvas area, and blur inputs when the Pencil touches the canvas **[verify]** |
| Long press | Safari shows callouts and the selection magnifier | Suppressed with the CSS above. The custom 500 ms recognizer opens Radix context menus |
| Hardware keyboard (Magic/Smart Keyboard) | `keydown` works | Optional shortcuts only. Every action also has a touch path |
| **Web Workers (module)** | Supported (Safari 15+) | Used for import, meshing, IO and export |
| OffscreenCanvas 2D / WebGL | 2D since 16.4, WebGL since 17 | Worker export rendering on 17+, with a main-thread fallback |
| `createImageBitmap` | Supported | Decode PNG blobs for texture upload |
| **WebAssembly** (+ SIMD) | Supported (SIMD since 16.4) | Not required initially. Available for hot paths |
| **IndexedDB** | Supported; Blob storage supported | Primary storage |
| Storage quota | Much larger since Safari 17; check with `navigator.storage.estimate()` | Show usage in the UI, and warn at 80% |
| **Eviction (ITP)** | In a Safari *tab*, script-writable storage can be deleted after 7 days without a visit. **Home Screen web apps are exempt** | Strongly encourage installation. Request `persist()`. Offer "Export backup" reminders |
| Origin Private File System | Supported (sync access handles in workers) | Optional future cache for large blobs; not required |
| File System Access pickers (`showSaveFilePicker`) | **Not supported** | Open with `<input type=file>`. Save through the Web Share sheet ("Save to Files") or a download link |
| Web Share API with files | Supported | Primary "Save/Export" path on iPad |
| **Service worker / PWA** | Supported. Add to Home Screen gives standalone display | `vite-plugin-pwa`. Must be served over HTTPS |
| Web App Manifest | Supported, with iOS-specific icons/splash via `apple-touch-icon` | Provide both |
| WebCodecs `VideoEncoder` (H.264) | Available in recent Safari versions **[verify codec configurations]** | MP4 export path. Fallback is MediaRecorder or a PNG sequence |
| `MediaRecorder` + `canvas.captureStream()` | Supported (MP4) | Real-time fallback export |
| Web Audio + `getUserMedia` (mic) | Supported, with a permission prompt | Later: microphone lip-sync for mouth parameters |
| Vibration API (haptics) | Not supported | Visual feedback only |
| Orientation changes | `resize` / `screen.orientation` | Separate persisted panel layouts for portrait and landscape |
| Safe areas | `env(safe-area-inset-*)` | Applied in the shell layout |

## 4.2 Memory: the dominant constraint

On a 4 GB device the Safari web content process is terminated by the OS (jetsam) well before
the total RAM is used. The practical ceiling is likely **somewhere around 1–1.5 GB** for one tab
or PWA, including the GPU memory attributed to it. This is unverified, and the M1 spike will
measure it with a stress page that allocates textures until it fails. Until measured, the
**budget is 600 MB** in total.

**M0 update (run 1, Claude app):** 2 GB of GPU textures and, separately, 2 GB of JS memory
were allocated without failure. The provisional budget is now **1 GB combined**, pending a
4 GB-cap run and a Safari/PWA run.

**M0 run 2:** iPadOS killed the page at **≈2.6 GB** in both the JS probe (2,624 MB) and the GPU
probe (2,640 MB), which points to one shared per-process limit. **Budget: 1.3 GB combined (JS +
GPU)**, re-measured as an installed PWA in M1 acceptance.

| Consumer | Typical size | Strategy |
|----------|--------------|----------|
| Artwork textures (GPU) | 2–4 atlas pages × 4096² × 4 B = 64 MB each | Crop layers to their bounds and pack them. Half-resolution "preview quality" atlas. Optionally compressed textures (ASTC is supported by Apple GPUs; WebGL extension availability **[verify]**) |
| Decoded layer pixels (CPU) | Transient during import | Never keep `ImageData` after upload. Keep only PNG blobs in IndexedDB |
| PSD file buffer | Size of the file (100–500 MB for large illustrations) | Read in a worker. Decode one layer at a time where possible (doc 05), and release the buffer after import |
| Geometry and keyforms | Small (30k verts × 8 B × keyforms) ≈ a few MB | Typed arrays |
| Undo history | Capped at 64 MB | Diff-based commands |
| JS heap / React | 50–150 MB | Virtualized lists; no per-frame allocation |

The diagnostics panel shows estimated GPU memory (tracked by the renderer), the JS heap where
available, and the texture inventory.

## 4.3 Performance expectations (A14)

- A14 has a capable GPU. Drawing about 200 textured meshes with alpha blending at 2360×1640 is
  expected to be fine. Fill rate is the main cost, which is why the render-scale setting exists.
- CPU budget per 16.7 ms frame: evaluation ≤4 ms, physics ≤1 ms, draw submission ≤3 ms,
  overlays ≤2 ms, leaving headroom for React and the GC.
- Target model for acceptance testing: about 150 ArtMeshes, 30k vertices, 40 deformers,
  30 parameters, 6 physics groups, and two 4096² atlas pages at **60 fps** during parameter
  preview, measured on the device.

## 4.4 Development without a Mac

| Need | Approach |
|------|----------|
| Build and run | Linux/Windows dev machine, Vite dev server over HTTPS on the LAN, opened on the iPad |
| Deployed previews | Static hosting (GitHub Pages, Cloudflare Pages or similar) per branch, so the PWA can be installed |
| Debugging on iPad | **Safari Web Inspector requires a Mac**. Mitigations: an in-app diagnostics panel, an `eruda` console in debug builds, error reporting to an in-app log that can be exported, and optionally `ios-webkit-debug-proxy` from Linux/Windows (community tool, reliability varies) |
| Automated tests | Playwright WebKit on Linux CI approximates the Safari engine. Device-specific behaviour (Pencil, memory limits, eviction) is checked manually per milestone |

No Xcode, native wrapper or App Store submission is required for the PWA. A native wrapper (for
example Capacitor) remains a future option if PWA limits turn out to block the product. That
would need a Mac or a cloud Mac build service.

## 4.5 Verdict

iPad Safari is a **viable** platform for this editor. WebGL2, Pointer Events with Pencil,
workers, IndexedDB and PWA installation cover every core need. The binding constraints are:

1. **Per-tab memory.** This drives texture cropping, atlasing, per-layer streaming import and the
   absence of duplicate pixel copies.
2. **Storage eviction risk outside an installed PWA.** Mitigated by installation, `persist()`
   and export reminders.
3. **No pressure on the USB-C Pencil, and no hover on this device.** The UI must not depend on
   either.
4. **No Web Inspector without a Mac.** Built-in diagnostics are required from M1.

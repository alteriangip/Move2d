# M0 Results: iPad Run 1

Run `run-20261107-1216-uavbz`, 2026-11-07. Raw data: [ipad-run1.json](ipad-run1.json).
Decision rules: [protocol.md](protocol.md) (fixed before this run).

## Test conditions (read these first)

| Condition | Value | Consequence |
|-----------|-------|-------------|
| Device | iPad, screen 820×1180 pt at 2× (matches iPad 10th gen), Apple GPU, 16384 max texture | Correct target |
| Browser shell | **Claude iPad app (WKWebView)**, not Safari. UA contains `Claude/1.261104.19` | Same WebKit engine and JIT as Safari, but **memory limits and storage policy can differ** from Safari and from an installed PWA |
| Hosting | claude.ai artifact (cross-origin iframe) | Third-party storage rules apply; Web Share and service workers unavailable |
| Viewport | **460×820 CSS px** (side panel), so the benchmark backbuffer was 920×1468 (1.35 MP) | **Full-screen fill rate (2360×1640 = 3.9 MP) is not yet measured** |
| Timer resolution | 1 ms (all timings are integers) | Per-frame values below 2 ms are quantized. Lab fixed to batch measurements (v2) |
| Device label | Not entered | iPadOS version unknown (the UA is desktop-class) |

## Outcomes per decision rule

### 1. GPU deformation: **decided: not needed for the target model**

| Preset | Vertices | CPU eval p50/p95 (ms) | Frame rate |
|--------|----------|-----------------------|------------|
| target | 29,400 | 1 / 2 | 60 fps (display-capped) |
| x2 | 58,800 | 2 / 3 | 60 fps |
| x4 | 117,600 | 3 / 3 | 60 fps |
| x8 | 240,000 | 4 / 4 | 60 fps |

- Target model eval p95 = 2 ms against the 4 ms budget, and 60 fps. By the rule,
  **GPU deformation is not required.**
- **Measured CPU-deformation limit: about 240,000 vertices (8× the target model) at about 4 ms
  per frame.** The linear fit extrapolates further (334k), but it rests on 1 ms-quantized data,
  so the documented limit is the measured 240k.
- **When GPU deformation becomes necessary:** for models above about 240k simultaneously
  deforming vertices, or when profiling of the *real* editor (with overlays and UI on the main
  thread) leaves less than 4 ms for evaluation. Dirty tracking (doc 01 §1.5.3) means typical
  frames evaluate only a fraction of the model, which adds further headroom.
- Transform feedback works on the device (100k vertices, 0 mismatches), so the GPU path remains
  open.
- *Pending:* fill rate at full-screen resolution (run 2, full screen).

### 2. Memory budget: **provisional: 1 GB, pending a 4 GB-cap run**

| Probe | Cap chosen | Reached | Failure |
|-------|-----------|---------|---------|
| GPU textures (16 MB each, drawn so they are resident) | 2 GB | 2,048 MB | none |
| JS ArrayBuffers (64 MB, every page touched) | 2 GB | 2,048 MB | none |

The real ceiling is **above 2 GB for each, measured separately**, inside the Claude app. The
rule ("50% of the lower ceiling") gives a provisional budget of **1 GB combined (GPU + JS)**,
which is more than the 600 MB placeholder. Two caveats keep it provisional: the true ceiling was
not reached, and Safari or a Home Screen PWA may have different limits. *Pending:* a run with the
4 GB cap, ideally in Safari or Pages.

### 3. PSD import strategy: **decided: ag-psd, lazy per-layer decoding**

| File | ag-psd lazy | ag-psd eager | @webtoon/psd | Fidelity |
|------|-------------|--------------|--------------|----------|
| small (40 layers) | 34 ms / 5 MB | 20 ms / 31 MB | 62 ms / 4 MB | 0 mismatches (all) |
| medium (100 layers, 3000×4500) | 179 ms / 14 MB | 76 ms / 127 MB | 180 ms / 8 MB | 0 mismatches (all) |
| large (150 layers, 4000×6000) | 328 ms / 28 MB | 197 ms / 330 MB | 381 ms / 17 MB | 0 mismatches (all) |
| **your PSD** (2480×3508, 16 layers, 17 MB) | **157 ms / 66 MB** | 124 ms / 177 MB | **FAILED: "Out of bounds access"** | n/a |

(time / accounted peak memory)

- **@webtoon/psd failed on the only real-world file tested.** It is rejected, not just
  demoted.
- ag-psd lazy has 12× lower peak memory than eager on the large file, at roughly 1.6× the time
  (still about 0.3 s for 150 layers). It is chosen for M1.
- Crop + PNG encode costs **about 50 ms per megapixel** (stable across files). Your file
  (42 MP of layers) takes about 2.1 s, so encoding runs in a worker with a progress bar.
- PNG output is 2–5% of raw size. The stored project will be small.

### 4. Texture pipeline and context loss: **decided: 4096² atlas pages; restore path as planned**

| Size | PNG encode | Decode (createImageBitmap) | Upload from ImageBitmap | Upload from typed array |
|------|-----------|----------------------------|-------------------------|-------------------------|
| 2048² | 205–233 ms | 54 ms | 105 ms | 10 ms |
| 4096² | 635–740 ms | 117 ms | **348 ms** | **86 ms** |

- 4096² decode (117 ms) is under the 500 ms rule, so **4096² atlas pages are allowed**
  (`MAX_TEXTURE_SIZE` 16384).
- Context loss and restore work (restore 1 ms). Rebuilding two 4096² atlases is estimated at
  about 1 s (under the 2 s rule), so no extra decoded copy is kept.
- **New finding:** uploading from an `ImageBitmap` is **4× slower** than uploading raw pixels.
  M1 will compare "decode to pixels in a worker, upload a typed array" against "upload the
  ImageBitmap" before fixing the texture loader.
- ASTC (LDR and HDR), ETC and PVRTC are available. Compressed textures are cheaper than assumed
  (an encoder is still needed).

### 5. Storage: **partially decided; Safari/PWA run needed**

- Quota in this context: 922 MB. `persist()` returned **false** (expected inside a
  third-party frame).
- **IndexedDB failed to store a `Blob`** ("The object can not be found here"), while a plain
  object in the same database succeeded. This is WebKit's third-party-frame restriction.
  **M1 decision:** store binary data as `ArrayBuffer`, not `Blob`. It works in every context
  and costs nothing. Lab v2 measures both.
- OPFS works (32 MB write in 59 ms).
- *Pending:* persistence and eviction as a first-party Safari page and as a Home Screen app
  (hosting B).

### 6. Video export: **decided: WebCodecs H.264 MP4 is viable**

- H.264 (Baseline/Main/High, up to 4K) and HEVC encoders are available. **1080p encodes at
  87 fps**, about 3× faster than real time.
- VP9 with alpha is unsupported, so **transparent video is impossible on this device**.
  Transparent output will be a PNG sequence (added to the feature register).
- Encoding also works in a worker (`VideoEncoder` in worker: ok).

### 7. Pencil and touch: **Pencil decided; finger/palm/long-press steps missing**

| Measure | Result |
|---------|--------|
| Pencil event rate | 118 Hz median, with ≈4 coalesced samples per event (`getCoalescedEvents` works) |
| Pressure | **Real: 140 distinct levels, 0–0.64.** This implies a 1st-generation Apple Pencil, since the USB-C model has no pressure. Please confirm |
| Tilt | Real (tiltX 18–41°, tiltY 14–35°); altitude/azimuth provided |
| Predicted events | Available |
| Scribble | Text entered in the field; no interference with canvas strokes |
| Page zoom | No leak, but no pinch was recorded, so this is untested |
| **Finger, two-finger, palm, long-press** | **No touch pointer data was recorded** (2 `touchstart`s, 0 touch `pointerdown`s) |

It cannot be determined from the data whether the finger steps were skipped or whether the
Claude app's panel intercepted the touches. That matters, because palm rejection and two-finger
navigation are core to the UI. Lab v2 shows a live checklist of which steps were captured.

### 8. Other platform facts recorded

- Workers: module workers, OffscreenCanvas WebGL2 in workers, IndexedDB, createImageBitmap and
  VideoEncoder in workers all **ok**. The architecture's worker plan is confirmed.
- WebAssembly instantiates. The **SIMD result is void**: the lab's probe bytes were invalid
  (they also returned false in Chromium). Fixed in v2.
- No `performance.memory` and no `measureUserAgentSpecificMemory`, as expected. Memory stays
  accounted plus crash-tested.
- `requestIdleCallback` and `scheduler.yield` are absent. Background scheduling uses
  `setTimeout` / `MessageChannel`.

## Architecture changes justified by run 1

| Change | Evidence | Where |
|--------|----------|-------|
| CPU deformation confirmed. GPU path deferred, triggered at more than ~240k vertices or less than 4 ms headroom in real-editor profiling | §1 | doc 01 §1.5.4, feature register |
| PSD import = ag-psd lazy (`useRawData` + `getLayerImageData`), with an ImageData factory and a verification that every layer produced pixels. @webtoon/psd removed | §3 | docs 03, 05 |
| Store binary data in IndexedDB as `ArrayBuffer`, not `Blob` | §5 | doc 01 §1.10.2 |
| Atlas page size 4096² allowed; restore from compressed PNGs (no extra decoded copy) | §4 | doc 01 §1.6 |
| M5 video = WebCodecs H.264/MP4. Transparent video = PNG sequence only | §6 | roadmap M5, feature register |
| Memory budget raised from 600 MB to a provisional 1 GB | §2 | doc 04 §4.2 |

## Needed in run 2 (lab v2, same link)

1. Enter the device label: iPadOS version and Pencil model.
2. Open the lab **full screen** (not in the side panel) and re-run **Rig benchmark** to measure
   full-resolution fill rate.
3. Re-run **Apple Pencil & touch input** and complete the finger, two-finger, palm and
   long-press steps (the checklist shows ✓ for each).
4. Run both **memory ceilings with the 4 GB cap**.
5. Optional but valuable: the same lab as a first-party Safari page / Home Screen app (GitHub
   Pages) for `persist()`, Blob storage and memory limits outside the Claude app.

# M0: Container Baseline (not iPad data)

Run: headless Chromium 153 in the Linux development container, **software GPU (SwiftShader)**,
1180×820 at 1×. Purpose: prove every experiment runs end to end and catch bugs before the
iPad run. **None of these numbers predict iPad performance.** GPU-bound figures (fps,
uploads) are especially meaningless on a software rasterizer.

Raw report: [container-baseline.json](container-baseline.json) ·
Screenshot: [img/container-lab-overview.png](img/container-lab-overview.png)

## Result: all 9 experiments ran, 0 console errors

| Experiment | Status | Notable |
|------------|--------|---------|
| WebGL2 capabilities | ok | Transform feedback verified correct on 100k vertices (0 mismatches) |
| Context loss & restore | ok | Lost and restored events fire; context usable after restore |
| Texture pipeline | ok | 4096²: PNG encode 1.4–1.6 s on the main-thread canvas, **~2× faster via OffscreenCanvas**; decode ~0.3–0.4 s |
| Storage | ok | IndexedDB ~400–470 MB/s write; `persist()` false in headless (expected) |
| Video export | ok | WebCodecs H.264 path works end to end (software encoder) |
| Rig benchmark | ok | CPU eval scales linearly (~0.054 µs/vertex p95); target model eval p95 1.8 ms |
| Pointer & touch | ok | Code path verified with synthetic mouse and touch; real Pencil data needs the iPad |
| PSD import | ok | All 4 strategies × 3 presets: **0 metadata mismatches** |
| GPU memory ceiling | ok | Reached the 1 GB cap (software GPU: not meaningful) |

## Findings already actionable (platform-independent)

These come from the library code itself, not from device speed, so they hold on the iPad as
well.

1. **ag-psd 34 supports per-layer lazy decoding** (`useRawData` + `getLayerImageData`). On the
   large preset (150 layers, 4000×6000, 318 MB of raw layer pixels), accounted peak memory is
   **≈28 MB for lazy vs ≈330 MB for eager**, for the same total time. That is about 12× less.
   The custom streaming decoder listed as a fallback in doc 05 is likely unnecessary. Lazy
   decoding becomes the M1 import strategy unless the iPad data contradicts it.
2. **ag-psd silently drops layer pixels when it cannot create ImageData** (no canvas: Node,
   Web Workers). In eager mode the layer simply has no `imageData` and no error is raised.
   Consequences for M1:
   - always call `initializeCanvas` with a canvas-free ImageData factory (done in
     `src/ag-init.ts`);
   - the importer must verify that every pixel layer with a non-empty area produced pixels,
     and report any failure. Never skip a layer silently.
3. **@webtoon/psd** gives the lowest peak memory (≈17 MB on large) but bundles a WASM decoder,
   and its last npm release is from **2023**. Whether WASM instantiates inside the claude.ai
   frame and on iPad Safari is measured by the lab (`features.wasmInstantiate`).
   Maintenance risk makes it the backup, not the default.
4. **Crop + PNG encode costs about 40–70 ms per megapixel** here. PNG output is about 2% of raw
   size for flat-colour artwork. Encoding must happen in a worker (OffscreenCanvas) during
   import.
5. **A real bug caught by the unit tests:** the first keyform weight helper returned a shared
   scratch object, so the second parameter axis overwrote the first. Fixed before any
   measurement. This is a concrete example of why rule 15.8 (tests for interpolation) matters.
6. **A benchmark artefact caught by the baseline:** without a warm-up, the first preset
   measured JIT tier-up rather than steady state, which inflated its p95 by 2.4× and skewed the
   fitted model-size limit. A discarded 400 ms warm-up was added.

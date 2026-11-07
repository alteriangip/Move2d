# M0 Results: iPad Run 2

Submitted 2026-11-07 10:34 UTC. Raw data: [ipad-run2.json](ipad-run2.json). Run 1:
[results-ipad-run1.md](results-ipad-run1.md).

Run 2 re-used run 1's report (no "Start a new run"). Run 1's raw data had already been saved in
the repository, so nothing was lost. Re-run in run 2: rig benchmark, storage, texture pipeline,
video, WebGL, context loss, and both memory ceilings. **Not re-run:** Pencil & touch, PSD (run 1
values stand). Device label still empty.

## Conditions

| Condition | Run 2 |
|-----------|-------|
| Shell | Claude iPad app (WKWebView), claude.ai frame |
| Viewport | **1180×820 CSS px, full screen, landscape** (run 1: 460 px side panel) |
| Benchmark backbuffer | **2360×1468 = 3.46 MP** (run 1: 1.35 MP) |
| Timer resolution | 1 ms (CPU timings are now batched ×10, so they resolve sub-millisecond) |

## 1. Rendering at full resolution: **decided**

Every pass ran at **60 fps with 0 frames over 20 ms**, including 240k vertices at full
resolution and the render-only passes. Frame time p95 was 17 ms (the display's refresh interval).

| Preset | Vertices | CPU eval, batched p50 / p95 (ms) |
|--------|----------|----------------------------------|
| target | 29,400 | **0.5 / 0.7** |
| x2 | 58,800 | 0.6 / 0.9 |
| x4 | 117,600 | 1.3 / 1.3 |
| x8 | 240,000 | 2.6 / 2.6 |

- About 0.011 µs per vertex. The 4 ms budget is reached at roughly **360–400k vertices**
  (extrapolated; the measured point is 240k at 2.6 ms).
- **GPU deformation: not needed.** The trigger in the feature register moves from "~240k" to
  "**more than ~350k simultaneously deforming vertices**, or under 4 ms of evaluation headroom in
  real-editor profiling".
- Fill rate is not a bottleneck at 3.46 MP for this scene. Limit of the test: the synthetic
  scene's overdraw is moderate, and there is no GPU timer, so GPU headroom beyond 60 fps is
  unknown. The reduced-quality render-scale setting stays as a safety valve, not a default.

## 2. Memory ceiling: **decided for this shell**

| Probe | Cap | Reached | Outcome |
|-------|-----|---------|---------|
| JS ArrayBuffers | 3 GB | **2,624 MB** | **Page killed by iPadOS** while allocating the next 64 MB |
| GPU textures | 3 GB | **2,640 MB** | **Page killed by iPadOS** while allocating the next 16 MB |

Both kills were recorded by the crash breadcrumb and recovered on reload. The two separate
probes die at almost the same point (≈2.6 GB), which indicates **one process-wide limit of about
2.6 GB** shared by JS and GPU memory. That is consistent with WebKit attributing GPU allocations
to the web content process.

**Rule outcome:** budget = 50% of the lower ceiling = **1.3 GB combined (JS + GPU)**. This replaces
the provisional 1 GB.

Caveat: measured in the Claude app's web view. Safari and a Home Screen PWA use the same WebKit
process model and are expected to be similar but are unverified. The M1 acceptance checklist
re-measures the installed PWA.

## 3. Storage: **decided (ArrayBuffer)**

- `Blob` in IndexedDB: **fails again** (`NotFoundError`). This is reproducible in the
  claude.ai frame.
- `ArrayBuffer` in IndexedDB: **941 MB/s write, 1,482 MB/s read**, complete read-back. That
  confirms the run-1 decision.
- Eviction marker: survived between the runs (17 minutes; says nothing about the 7-day rule).
- `persist()` is still false in the frame. Persistence as an installed app remains unmeasured.

## 4. Texture pipeline and video: **unchanged**

- 4096²: decode 144 ms, upload from ImageBitmap 367 ms, from typed array 90 ms. This matches
  run 1, so the "upload raw pixels" comparison stays an M1 task.
- 1080p H.264 encode: 89 fps (run 1: 87).

## Still open

| Item | Why it matters | Proposal |
|------|----------------|----------|
| **Finger, two-finger, palm and long-press input** (no data in either run) | Palm rejection and two-finger navigation are core to the editor UI | **Required before M0 sign-off**: a 2-minute re-run of "Apple Pencil & touch input" until all checklist items show ✓ |
| Device label (iPadOS version, Pencil model) | Reproducibility | Enter it with the touch re-run |
| Persistence and eviction as a Home Screen app | Data safety | **Move into M1 acceptance.** The architecture already assumes the worst case (install prompt, `persist()`, export reminders, `ArrayBuffer` storage), so the result cannot change the M1 design |

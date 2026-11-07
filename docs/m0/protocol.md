# Milestone 0: Measurement Protocol

Status: iPad run 1 complete ([results](results-ipad-run1.md)); run 2 requested for the missing items.

Milestone 0 replaces the **[verify]** assumptions in
[04-ipad-safari-compatibility.md](../04-ipad-safari-compatibility.md) with measurements from
the target device (iPad 10th generation, A14, 4 GB RAM). The code lives in
[`spikes/m0-lab/`](../../spikes/m0-lab). It is throwaway spike code. Its only product is data.

The decision rules below were **fixed before any iPad data existed**, so the results cannot be
interpreted to fit a preferred conclusion.

## How to run it on the iPad

There are two hostings, because some behaviours differ between them:

| Hosting | URL | What it can measure | What it cannot |
|---------|-----|--------------------|----------------|
| **A. claude.ai artifact** (primary) | link given in chat | Everything except installed-app behaviour; results are submitted straight back to Claude | Runs inside an iframe on claude.ai. Web Share, service workers and storage persistence are refused by the frame, and memory ceilings include claude.ai's own page |
| **B. GitHub Pages** (optional) | `https://<owner>.github.io/<repo>/` after enabling Pages | Home Screen install, standalone mode, `persist()`, eviction, and memory ceilings without claude.ai in the process | Results are returned with Share/Copy (paste the JSON into chat) |

Order of a session:

1. Close other apps. Plug in the charger. Use landscape. Disable Low Power Mode.
2. Enter the device label (iPadOS version and Pencil model).
3. **Run all automatic tests** (about 2 minutes, with a fullscreen benchmark in the middle).
4. **Apple Pencil & touch input**: follow the six on-screen steps.
5. **PSD import**: run the synthetic presets, and optionally add one of your own PSDs. Only
   counts and timings are recorded, never layer names or pixels.
6. Take screenshots of the results section (top button + volume up).
7. **Submit results to Claude.**
8. Last, run **GPU texture memory ceiling** and then **JS memory ceiling**. iPadOS may reload
   the page. If it does, reopen the lab: the result is recovered automatically from the crash
   breadcrumb. Submit again.

## Experiments and the decision each one drives

| Experiment | Measures | Decision rule (pre-registered) |
|------------|----------|--------------------------------|
| WebGL2 capabilities | Limits, extensions, ASTC, MSAA, **transform feedback correctness** | If TF fails, GPU deformation must use a texture-based render-to-buffer path instead (record as "expensive"). `MAX_TEXTURE_SIZE` sets the maximum atlas page size: 4096 unless the measured value is lower |
| Context loss & restore | Restore latency, rebuild cost | Restore path required regardless. If the measured rebuild time extrapolated to the target model (two 4096² atlases) exceeds 2 s, keep a GPU-ready decoded copy of only the *visible* atlas |
| Texture pipeline | PNG encode/decode/upload at 2048² and 4096² | Sets the import and restore time budget. If 4096² decode exceeds 500 ms, prefer 2048² atlas pages |
| Storage | Quota, `persist()`, IndexedDB MB/s, eviction marker | If `persist()` is false in a Safari tab but true when installed, **M1 must prompt installation before the first save**. IndexedDB write below 20 MB/s means autosave must be incremental (dirty blobs only), which is already planned |
| Video export | WebCodecs configs, 1080p H.264 encode fps | If H.264 WebCodecs is unsupported, M5 export is PNG-sequence plus MediaRecorder only, and documented as such |
| **Rig benchmark** | CPU eval / upload / submit / frame time from 30k to 240k vertices; render-only pass; 0.5× scale | **GPU deformation becomes necessary when the target model (30k vertices) has eval p95 > 4 ms, or full-mode fps < 55 while render-only is ≥ 58.** The fitted vertices-at-4 ms is recorded as the model-size limit for CPU deformation. If render-only itself is < 55 fps at 1.0×, the bottleneck is fill rate and the default render scale drops |
| Pencil & touch | Event rate, pressure/tilt reality, coalesced events, cancels, palm contacts, zoom leakage, long-press side effects, Scribble | No feature depends on pressure or hover (already decided). If page zoom leaks, add `gesturestart` and `touch-action` guards at the document level. If Scribble alters the input, M1 blurs inputs on pen-down over the canvas. If coalesced events are absent, vertex dragging uses raw moves (acceptable) |
| PSD import | Time and accounted peak memory for 4 strategies; metadata fidelity; crop+PNG cost | Choose the strategy with the lowest peak memory that passes fidelity with 0 mismatches on all presets. If every strategy crashes on the large preset, the custom streaming decoder becomes M1 scope |
| GPU / JS memory ceilings | MB reached before failure or OS kill | **M1 memory budget = 50% of the lower ceiling measured in hosting B** (or in A, if B is not run, with that caveat noted). This replaces the 600 MB placeholder |

## Container baseline

A headless-Chromium run in the development container (Linux, software GPU) checks that every
experiment runs end to end and gives a desktop reference. Its numbers say **nothing** about the
iPad. Results: [container-baseline.md](container-baseline.md).

## What M0 cannot measure

- **Real memory usage.** Safari exposes no heap or GPU memory API. Peak memory is
  *accounted* (the sum of buffers we hold) and the ceiling is found by crash testing. That is
  the strongest evidence available on this platform without a Mac and Instruments.
- **Input latency** (Pencil to photon). That needs a high-speed camera, so it is out of scope.
- **Long-term eviction.** The marker only reports survival when the lab is reopened days later.
  A second visit after 7 or more days without opening it answers the ITP question.

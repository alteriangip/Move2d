# Feature Status Register

Every feature that is not working today falls into exactly one category. The register is
updated at each milestone sign-off. "Evidence" says how the classification is known.

| Category | Meaning |
|----------|---------|
| **Impossible** | Cannot be done on this platform, with this hardware, or within the project's legal rules, whatever the effort. Workarounds are listed, never presented as the feature |
| **Expensive** | Technically possible, but needs significant extra work, measurable runtime cost, or an outside dependency (such as a licence). Scheduled only on evidence of need |
| **Not yet implemented** | Planned in a milestone. Absent from the UI or visibly disabled until then |

## Impossible

| Feature | Why | Evidence | Workaround |
|---------|-----|----------|------------|
| Pencil pressure on Apple Pencil (USB-C) | Hardware has no pressure sensor | Apple specs; M0 pointer lab records `pressureLooksReal` | No feature depends on pressure (owner decision) |
| Pencil hover on iPad 10th gen | Hardware/OS supports hover only on newer iPad Pro/Air models | Apple specs | No hover UI anywhere (owner decision) |
| Pencil double-tap / squeeze from a web app | Not exposed to web content | WebKit API surface | On-screen modifier buttons |
| Native "Save As" dialogs (File System Access API) | Not implemented in Safari | Feature probe in M0 (`showSaveFilePicker`) | Share sheet → "Save to Files"; `<input type=file>` to open |
| Safari Web Inspector without a Mac | Apple requires a Mac to attach | Platform fact; owner has no Mac | In-app diagnostics panel, log export, eruda |
| Exact JS heap or GPU memory readings in Safari | No API exposed | M0 probes `performance.memory` and `measureUserAgentSpecificMemory` | Accounted memory plus crash-threshold testing |
| Exporting genuine `.moc3` | Undocumented proprietary binary. Reverse engineering is excluded by project rules | Doc 05 | Native `.olive` format and an OpenLive runtime |
| Recovering deformers/keyforms from a `.moc3` | Cubism Core exposes only post-deformation drawables | Core API reference (doc 05) | "Baked" mesh-only import, labelled as such |
| Transparent (alpha) video export | No alpha-capable video encoder on the device (VP9+alpha unsupported, M0) | M0 video probe | PNG sequence with alpha |
| Haptic feedback | Vibration API absent on iOS | M0 feature probe (`vibrate`) | Visual feedback |

## Expensive

| Feature | Cost | Trigger to schedule it |
|---------|------|------------------------|
| GPU deformation (transform feedback) | About +30% of M2/M3 rig work; dual implementation with the CPU reference | **M0 measured: not needed for the target model** (2 ms p95). Trigger: models above ~350k simultaneously deforming vertices (run 2, full screen: 240k vertices = 2.6 ms), or under 4 ms of evaluation headroom in real-editor profiling. Transform feedback verified working on the iPad |
| Free-form warp control points | New interpolation (mean-value or harmonic coordinates); about +2 weeks | Owner request after M3. The architecture keeps the warp mapping behind a `WarpMapping` interface so a free-form variant can be added without rewriting the deformer system |
| Blend modes beyond normal/add/multiply | Framebuffer ping-pong per blended drawable; costs fill rate | Artist demand after M2 |
| Cubism model preview (Stage 1) | Live2D review and special Publication License for "Expandable Applications" | Owner decision plus a written answer from Live2D |
| Numerically identical Cubism physics | Undocumented solver details | Not planned. The import is documented as approximate |
| PSD layer effects, adjustment layers, exact 16/32-bit or CMYK | Re-implementing Photoshop rendering | Not planned. Warnings shown at import |
| ASTC compressed textures | In-browser ASTC encoder (WASM), plus quality and time cost | Memory pressure measured in M0/M1 |
| Native app wrapper (App Store) | Needs a Mac or a cloud Mac build service | Only if PWA limits block core features |

## Not yet implemented

Everything in the [roadmap](06-roadmap.md) from Milestone 1 onward. As of M0 there is no
editor code, only the measurement lab (`spikes/m0-lab`).

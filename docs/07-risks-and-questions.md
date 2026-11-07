# 7. Technical Risks and Unresolved Questions

## 7.1 Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| R1 | **Safari tab memory limit** kills the app on large projects or PSDs | High | High | M0 measurement; 600 MB budget; cropped and atlased textures; one-layer-at-a-time import; no retained `ImageData`; half-resolution preview atlases; memory readout in diagnostics |
| R2 | **Live2D licensing** blocks public release of Cubism model import (Expandable Application) | High | Medium | Isolated optional `cubism-bridge`; Core never bundled; the native editor does not depend on it; decision needed (Q1) |
| R3 | **No Web Inspector without a Mac** slows debugging of iPad-only bugs | High | Medium | In-app diagnostics and log export from M1; eruda in debug builds; Playwright WebKit in CI; optionally borrow or rent Mac access for hard cases |
| R4 | WebGL **context loss** on iPadOS loses GPU state | Medium | High | Full rebuild path from CPU data and blobs; tested via `WEBGL_lose_context` in E2E |
| R5 | **Storage eviction** in a Safari tab (7-day ITP) deletes projects | Medium | High | Prompt to install the PWA; `persist()`; periodic "export backup" reminders; autosave never treated as the only copy |
| R6 | CPU deformation exceeds the frame budget on large rigs | Low–Medium | Medium | Dirty tracking; zero-allocation evaluator; benchmark harness in CI; transform-feedback escalation path |
| R7 | **Keyform combinatorial explosion** with multi-parameter bindings | Medium | Medium | Cost shown in the UI; limit of 3 bound parameters in M3; additive blend shapes later |
| R8 | **Topology edits after keyforms exist** corrupt or distort keyforms | Medium | High | Compound commands updating all keyforms via barycentric insertion; property tests; warning dialog for destructive operations |
| R9 | Numerical robustness of the inverse warp (folded or degenerate grids) | Medium | Medium | Analytic plus Newton solver with fallbacks; fuzz tests; warnings on folded cells |
| R10 | Rotation-inside-warp behaviour feels wrong to artists | Medium | Medium | Design spike in M3; parameterize the Jacobian approximation; artist feedback |
| R11 | PSD edge cases (CMYK, 16-bit, effects, unusual blend modes) | High | Low–Medium | Explicit warnings per layer; fixture corpus; never fail silently |
| R12 | Pencil/touch quirks (Scribble capture, `pointercancel`, palm contacts) | Medium | Medium | M0 logger; pen-priority policy; configurable touch behaviour |
| R13 | WebCodecs availability or codec differences on Safari | Medium | Low | Feature detection; PNG-sequence export always available; MediaRecorder fallback |
| R14 | Service-worker update bugs on iOS leave users on stale versions | Medium | Low | Explicit "update available" prompt; versioned caches; manual "reload app" in settings |
| R15 | **Scope.** This is a very large product, and quality can drop if it is rushed | High | High | Strict milestone gating; acceptance tests; no stub features |
| R16 | Test-fixture licensing (sample PSDs and models) | Medium | Low | Commission or create our own fixtures; document licences in `fixtures/LICENSES.md` |
| R17 | React re-render cost while scrubbing parameters | Medium | Medium | The viewport does not render through React; fine-grained revision selectors; profiling in CI with React Profiler snapshots |
| R18 | Physics doesn't match Cubism numerically when importing `physics3.json` | High | Low | Documented as approximate; side-by-side comparison; no "identical" claim |

## 7.2 Questions requiring a decision from the project owner

1. **Licensing and distribution of OpenLive itself.** Will it be open source? Under which licence
   (MIT, Apache-2.0, GPL)? Will it be commercial? Who is the publishing entity? This determines
   whether and how to approach Live2D about Cubism model import.
2. **Is Cubism model import a must-have for public release, or acceptable as a private or
   development-only feature** until Live2D grants permission?
3. **Approval of the CPU-evaluation / GPU-rendering split** (doc 01 §1.5.4), or should GPU
   deformation be required from M3?
4. **Monorepo with pnpm workspaces:** acceptable? Any preference for npm or yarn?
5. **Minimum iPadOS version.** The proposal is iPadOS 17. Is that acceptable?
6. **Test hardware.** Is an iPad 10th gen available? Which Pencil: 1st gen (pressure) or USB-C
   (no pressure)? Is any Mac available, even occasionally, for Web Inspector?
7. **Hosting** for the PWA and preview builds (GitHub Pages, Cloudflare Pages, other). An HTTPS
   origin is required.
8. **Fixture artwork.** Can you provide layered PSD characters we may use in the repository's
   test suite, or should we create simple ones?
9. **Warp deformer "custom control grids."** Is a regular grid with insertable rows and columns
   enough, or are free-form (non-grid) control layouts required? Free-form needs a different
   interpolation scheme (for example mean-value coordinates) and roughly 2 extra weeks.
10. **Additional blend modes** beyond normal, additive and multiply: needed in M2, or later?
11. **Open-format interop priority.** Should Inochi2D (open puppet format) be investigated in M6?
12. **Naming.** The product is "OpenLive", the repository is "Move2d", and the proposed file
    extension is `.olive`. Confirm or rename.
13. **UI language(s)** and whether localization should be built in from M1.
14. **React version:** 19 (current) or 18? The proposal is 19 unless a dependency requires 18.

## 7.3 Known unknowns to be measured in Milestone 0

- The actual memory ceiling of a Home Screen PWA on iPad 10th gen.
- `MAX_TEXTURE_SIZE` and ASTC extension availability in WebGL2.
- Pointer coalesced/predicted event support, and Scribble behaviour over a canvas.
- Peak memory of ag-psd vs @webtoon/psd on a 150-layer, 4000×6000 PSD.
- Supported WebCodecs H.264 configurations (resolution and profile limits).
- Storage quota and the `persist()` grant behaviour in standalone mode.

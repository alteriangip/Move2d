# 5. Feasibility: PSD Importing and Live2D Interoperability

## Part A: PSD importing

### A.1 Format background

The PSD/PSB format is **publicly documented by Adobe** ("Adobe Photoshop File Formats
Specification"). Its layer section stores, per layer:

- a bounding rectangle (layers are *not* full-canvas, which matters for memory);
- name (Pascal string plus a Unicode `luni` block), opacity, visibility and blend mode;
- the clipping flag (clipped to the layer below);
- channel image data (raw, PackBits/RLE, or ZIP), plus an optional raster layer mask.

Groups are encoded as "section divider" layers (`lsct`), from which the tree can be rebuilt.
Reading PSD files is therefore legitimate, documented interoperability.

### A.2 Library choice

| Library | Strengths | Weaknesses |
|---------|-----------|------------|
| **ag-psd** (MIT, actively maintained) | Full layer tree with groups; names, opacity, visibility, blend modes, clipping, masks, effects metadata; PSB support; `useImageData` gives raw pixels without a canvas, so it runs in a worker; options to skip composite/thumbnail data | Decodes all requested layer pixels in one call, so peak memory is the file plus all layers. Does not re-render effects or text |
| **@webtoon/psd** (MIT) | Designed for the browser; decodes layer pixels **lazily per layer** (`await layer.composite()`), so peak memory is lower | Smaller feature surface; maintenance cadence to be checked |

**Plan:** the M1 spike benchmarks both libraries on a fixture set (a small file, a 4000×6000 file
with 150 layers, a PSB, and a 16-bit file). It measures peak memory, time and correctness on the
iPad. The PSD adapter sits behind an `ArtworkImporter` interface in `packages/io`, so the decision
can be changed later. If neither keeps peak memory within budget for large files, the fallback is
a **custom streaming layer-pixel decoder**: parse the structure with ag-psd
(`skipLayerImageData`), then decode each layer's channels ourselves from the documented
PackBits/raw encodings. That is bounded work.

### A.3 Import pipeline

1. The user picks a file. It is read as an `ArrayBuffer` and transferred to `import.worker`.
2. Parse the layer tree and metadata. Show the **import preview dialog**: tree, thumbnails,
   per-layer include/exclude, a "merge group into one drawable" option, and warnings.
3. For each included layer, one at a time: decode the pixels, apply the raster layer mask into
   alpha, convert to premultiplied RGBA8, crop to the alpha bounding box plus padding, encode to
   PNG, and transfer the PNG blob and its offset back. Release the pixels.
4. Create a `Part` per group and an artwork layer per pixel layer, preserving **name, order,
   visibility, opacity and hierarchy**. Each layer becomes an independently editable source
   for ArtMeshes. Nothing is flattened.
5. Optionally generate an initial ArtMesh per layer, either a quad or an automatic mesh (from M2).

### A.4 What is preserved, approximated or not supported

| PSD feature | Handling |
|-------------|----------|
| Layer names (Unicode) | Preserved |
| Layer order | Preserved, becomes initial draw order |
| Groups (nested) | Preserved as Parts |
| Visibility | Preserved. Hidden layers are imported hidden, or can be excluded in the dialog |
| Layer opacity | Preserved as drawable opacity |
| Group opacity | Preserved as Part opacity |
| Fill opacity | Multiplied into opacity, with a warning when it differs (it ignores effects, which we don't render anyway) |
| Per-pixel transparency | Preserved |
| Blend modes normal/multiply/linear dodge (add) | Mapped to renderer blend modes |
| Other blend modes (screen, overlay, …) | Imported as normal, **with a warning listing the affected layers** |
| Clipping (clipped layers) | Mapped to clipping masks (the clipped layer is masked by its base layer) |
| Raster layer masks | Baked into alpha at import, with a warning |
| Vector masks, layer effects (shadows, strokes) | Not rendered, with a warning. Recommend rasterizing in the paint app |
| Adjustment and fill layers | No pixel data to import, so skipped with a warning |
| Smart objects / text layers | The stored rasterized pixels are imported as a normal layer |
| 16/32-bit, CMYK, Lab | 16-bit converted to 8-bit. CMYK/Lab converted approximately or rejected with a message **[spike]** |
| PSB (large document) | Supported if the chosen library handles it **[spike]** |

**Feasibility verdict: high.** PSD layer import with hierarchy is well within reach. The risk
is memory on very large files, not correctness. PNG/JPEG import is trivial: one image becomes
one layer.

---

## Part B: Live2D interoperability

### B.1 What the official SDK is

The **Cubism SDK for Web** has two parts:

- **Cubism Core** (`live2dcubismcore.js`): a closed-source runtime under the **Live2D
  Proprietary Software License Agreement**. It is the only component that can read `.moc3`.
  Its API exposes **already-deformed runtime output**: per-drawable vertex positions for the
  current parameters, UVs, indices, opacity, draw order, masks, blend flags, texture index,
  parent part indices, and parameter and part IDs with min/max/default. It does **not** expose
  deformers, keyforms or the editing structure.
- **Cubism Web Framework**: open source under the **Live2D Open Software License**. It provides
  rendering, motion, physics and expression playback, and the parsers for the JSON companion
  files.

The SDK is a **runtime**. Loading a model with it gives a playable puppet, not an editable rig.

### B.2 Licensing findings

From Live2D's SDK licence pages (see the sources at the end):

- The SDK is free to download, subject to the Proprietary and Open Software License agreements.
- Publishing content that uses the SDK requires an **SDK Release License (Publication License
  Agreement)** for business entities. Individuals and small-scale enterprises are exempt
  **except for "Expandable Applications."**
- **Expandable Applications** (applications that load arbitrary user-supplied models, such as
  avatar systems) must be **reviewed and approved by Live2D** and need a **special Publication
  License Agreement before release**. The standard release licence does not cover them.

**Consequence for OpenLive:** an editor or viewer that loads arbitrary `.moc3` files would very
likely be classed as an Expandable Application. Shipping Cubism model import publicly, even
free and open source, likely requires prior approval from Live2D. This is a
**legal/business decision for the project owner** and is listed in doc 07.
Until it is resolved:

- No Cubism Core file is committed to the repository or bundled in builds.
- `cubism-bridge` is developed against a locally supplied Core, for private development and
  testing only, behind a build flag that is off by default.

### B.3 Staged plan (as requested, with feasibility)

| Stage | Description | Technical feasibility | Licensing status |
|-------|-------------|-----------------------|------------------|
| 1. Preview existing runtime models | Load `.model3.json` + `.moc3` + textures via Core; render with our renderer from Core's drawable output | **High**: the Core API gives everything needed to draw | Needs Core. Public release likely needs Expandable Application approval |
| 2. Read model3.json references | Parse the JSON manifest (moc, textures, physics, motions, expressions, pose, display info, user data) | **High**: documented JSON | Our own parser, written from public documentation. No Core needed for the JSON itself |
| 3. Textures, physics, motions | Import `physics3.json` into our physics groups and `motion3.json` into our motion tracks; textures are PNG | **High** for motions (curve segment types map 1:1 by design). **Medium** for physics: the concepts map, but numeric equivalence with Cubism's solver is not guaranteed and is tested side by side | Data files are user-owned. Model authors' own licences still apply |
| 4. Legitimate ecosystem interop | Ask Live2D about permitted use; evaluate **open** formats such as Inochi2D (open-source puppet format), and our own documented `.olive` format and a TypeScript runtime player | **Medium**: depends on Live2D's answer. Inochi2D format support needs its own feasibility check | Open formats carry no restriction |
| 5. Export to `.moc3` | — | **Not feasible**: undocumented proprietary binary, and reverse engineering is out of scope by rule | **Will not be claimed or attempted** |

### B.4 "Import a Cubism model as an editable project": limits

Because the Core exposes only post-deformation output, a `.moc3` cannot be converted into an
equivalent editable rig. Possible, clearly labelled options:

- **Baked import:** take drawables at default parameters and convert them to ArtMeshes with UVs
  and textures. Parts and draw order are preserved. There are **no deformers and no keyforms**.
  This is useful as a starting point for re-rigging.
- **Sampled import (research only):** sample the Core at parameter grid points to build flat
  per-mesh keyforms. This produces large, non-hierarchical rigs and may conflict with model
  licences and with the Core licence terms. It is **not planned** without explicit legal
  clearance.

The UI will state plainly: "Imported from a Cubism runtime model. Original deformers and
keyforms are not available."

### B.5 Export from OpenLive

- **Native `.olive`**: complete, documented and versioned. This is the primary format.
- **OpenLive web runtime** (post-M6): a small TypeScript player package (`rig` + `physics` +
  `animation` + `renderer`) that loads exported projects, so models can be used outside the
  editor.
- **Rendered output**: PNG sequences and MP4 (M5).
- **Cubism export**: none. This limitation is documented in the README and in the app's About
  screen.

### Sources

- [Live2D SDK Release License](https://www.live2d.com/en/sdk/license/)
- [Live2D Cubism SDK download and licence terms (Native)](https://www.live2d.com/en/sdk/download/native/)
- [Live2D Help: SDK licence notes](https://help.live2d.com/en/?p=2558)
- [Cubism Core API reference (r15, PDF)](https://cubism.live2d.com/sdk-doc/reference/NativeCoreAPIReference_jp_r15.pdf)
- [Cubism SDK manual: drawable vertex positions](https://docs.live2d.com/cubism-sdk-manual/drawablevertexpositions)
- [ag-psd on npm](https://npmjs.com/package/ag-psd) and [README (PSD structure notes)](https://github.com/magebitcom/ag-psd/blob/master/README_PSD.md)
- Adobe Photoshop File Formats Specification (public Adobe documentation)

Licence terms change. They must be re-read in full, and Live2D contacted, before any Cubism
feature is released.

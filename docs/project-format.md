# OpenLive Project Format (`.olive`), version 1

A `.olive` file is a ZIP archive:

| Entry | Content |
|-------|---------|
| `project.json` | UTF-8 JSON, below |
| `images/<assetId>.png` (or `.jpg`) | Image data of each layer, cropped to its visible pixels. Stored uncompressed in the ZIP (PNG/JPEG are already compressed) |

## `project.json`

```jsonc
{
  "generator": "OpenLive 0.1",
  "formatVersion": 1,
  "doc": {
    "formatVersion": 1,
    "id": "…", "name": "character",
    "width": 2480, "height": 3508,          // canvas size in px
    "rootIds": ["…"],                        // top-level nodes, top to bottom
    "nodes": {
      "<id>": { "kind": "group", "name": "Head", "parentId": null, "visible": true, "locked": false,
                "opacity": 1, "childIds": ["…"], "expanded": true },
      "<id>": { "kind": "layer", "name": "Eye L", "parentId": "<groupId>", "visible": true, "locked": false,
                "opacity": 1, "imageId": "<assetId>", "x": 220, "y": 200, "width": 50, "height": 40,
                "blendMode": "normal" | "multiply" | "additive", "clipping": false }
    },
    "createdAt": "ISO-8601", "updatedAt": "ISO-8601"
  },
  "assets": [ { "id": "<assetId>", "width": 50, "height": 40, "mime": "image/png", "path": "images/<assetId>.png" } ]
}
```

Rules:

- Child order is **top to bottom** (as in Photoshop). Draw order is the reverse.
- Effective opacity = product of the node's and its ancestors' opacity. Hidden ancestors hide
  their descendants.
- `x, y` is the layer's top-left corner on the canvas. Layer images are never scaled in v1.
- `clipping` is preserved from PSD. Rendering of clipping masks starts in format v2 / Milestone 2.

Validation on load (with readable error messages): the archive must contain `project.json`;
`formatVersion` must not be newer than the reader; the node tree must be consistent (every node
reachable exactly once, `parentId` matching its parent); and every referenced image must be
present. Files from newer versions are refused rather than misread.

Versioning: each format change bumps `formatVersion`, adds a migration function from the
previous version, and adds a golden fixture to the test suite.

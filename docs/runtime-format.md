# `.m2rt` runtime format (version 1)

A single compact file for shipping a character in a game. All integers are
**little-endian**.

```
offset  size  field
0       4     magic "M2RT"
4       2     version (1)
6       2     flags (0)
8       …     chunks
```

Each chunk: `tag[4] u32 length payload[length]`. Readers skip unknown tags.

| tag | payload |
| --- | --- |
| `RIG ` | zlib stream of compact JSON `{version, rig, animations, physics}` — same schema as `project.json` ([project-format.md](project-format.md)). Editor-only flags are cleared. |
| `ATLS` | `u16 pageIndex` followed by a PNG. The page is texture `atlas_<pageIndex>` in `rig.textures`. |
| `END ` | length 0; end of file. |

Textures are packed into atlas pages (≤ 4096², power-of-two, 2 px padding) and
every mesh's `uvs` are already remapped into its page, so `textureID` on a mesh
names the atlas page to bind. `textureRect` is retained for reference only.

## Playing a character

Per frame:

1. Start from each parameter's `defaultValue`.
2. Apply animation clips: for each track, evaluate its curve at the clip's local
   time (`loopMode`), then `override` (lerp by layer weight) or `additive`
   (add `value − default`).
3. Apply your game's own inputs (look-at, lip sync…) by setting parameters.
4. Step physics (fixed 1/120 s), which overwrites its output parameters.
5. For every mesh and deformer, blend keyforms (multilinear, see
   [architecture.md](architecture.md#keyforms)).
6. For each mesh vertex: `p = rest + offset`, then map through its deformer and
   each ancestor (warp: bilinear lattice; rotation: `origin + R(angle)·scale·(p − restOrigin)`).
7. Sort meshes by blended `drawOrder` (ties: hierarchy order, back first) and draw
   with premultiplied alpha, the mesh's blend mode and its masks (draw only where
   the mask meshes' texture alpha ≥ 0.5; inverted when `invertMask`).

The Swift reference runtime is the `M2DRuntime` product: `RuntimeFormat.read`,
`RigEvaluator`, `AnimationClip.apply`, `PhysicsSimulator`, `RenderListBuilder`.

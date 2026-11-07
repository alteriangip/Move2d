# `.move2d` project format (version 1)

A project is a **package directory** (shown as a single document in Files):

```
Character.move2d/
  project.json        the whole rig, animations and physics (UTF-8 JSON)
  textures/<id>.png   one straight-alpha RGBA PNG per texture
  thumbnail.png       optional 256×256 preview
```

`project.json` top level:

| key | type | |
| --- | --- | --- |
| `formatVersion` | int | `1`. Readers must refuse newer versions. |
| `rig` | RigModel | see below |
| `animations` | [AnimationClip] | |
| `physics` | PhysicsRig | |
| `metadata` | object | `createdAt`, `modifiedAt` (ISO-8601), `generator`, `sourceFileName` |

Vectors (`Vec2`) are encoded as `[x, y]`. Rectangles as `{"origin":[x,y],"size":[w,h]}`.
Coordinates are canvas pixels, origin top-left, y down. UVs are 0–1 within each texture.

### RigModel

```
name, canvasWidth, canvasHeight,
rootChildren: [id]                    // top-level hierarchy, front-most first
parts:   [{id, name, parentID?, children:[id], visible, opacity, locked, expanded}]
textures:[{id, name, width, height}]
parameters: [{id, name, minValue, maxValue, defaultValue, group, isCyclic}]
meshes: [{
  id, name, partID?, deformerID?, textureID, textureRect,
  mesh: {vertices:[Vec2], uvs:[Vec2], indices:[uint32]},   // 3 indices per triangle
  keyforms: KeyformGrid<MeshForm>,
  visible, locked, blendMode: "normal"|"additive"|"multiply"|"screen",
  maskIDs:[id], invertMask, sourceLayerID?
}]
deformers: [{
  id, name, parentID?, showHandles,
  type: "warp"     , warp: {rect, columns, rows, keyforms: KeyformGrid<WarpForm>}
  type: "rotation" , rotation: {restOrigin, handleLength, keyforms: KeyformGrid<RotationForm>}
}]
```

### KeyformGrid

```
{ "bindings": [{"parameterID": id, "keys": [float…]}…],
  "forms": [Form…] }      // count = product of key counts; first binding varies fastest
```

* `MeshForm`: `{offsets:[Vec2] (one per vertex), opacity, drawOrder}`
* `WarpForm`: `{points:[Vec2] ((columns+1)*(rows+1), row-major), opacity}`
* `RotationForm`: `{origin, angle (degrees), scale, opacity}`

### Animation

```
AnimationClip: {id, name, duration (s), frameRate, loopMode: "once"|"loop"|"pingPong", tracks}
ParameterTrack: {parameterID, enabled, blend: "override"|"additive", keyframes}
Keyframe: {id, time (s), value, interpolation: "constant"|"linear"|"bezier"|"easeIn"|"easeOut"|"easeInOut",
           outHandle: {x, y}, inHandle: {x, y}}   // bezier: x = fraction of segment, y = value offset
```

### Physics

```
PhysicsRig: {gravity: Vec2, wind: Vec2, groups}
PhysicsGroup: {id, name, enabled, translationScale, angleScale,
  inputs:  [{parameterID, kind: "translationX"|"translationY"|"angle", weight, reflect}],
  outputs: [{parameterID, particleIndex, angleRange, weight, reflect}],
  particles: [{length, stiffness, damping, mobility}]}
```

The reference implementation is `ProjectArchive` in `Sources/M2DProject`, which
also validates indices, keyform sizes and deformer cycles on load.

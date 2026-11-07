# Move2D

A phone and tablet app (Android and iOS) for viewing, posing and animating a rigged 3D character.

- **Load** a `.glb`, `.gltf`, `.vrm` or `.fbx` model. The app keeps it, so you only load it once.
- **Pose** with one-tap presets (attitude, combat and resting poses), or tap a joint and rotate it with the on-screen rings or the Bend / Turn / Tilt sliders.
- **Drag limb** mode moves a hand or foot and solves the elbow or knee for you (two-bone IK).
- **Move body** mode shifts the whole body (hips).
- **Hands**: per-finger curl and spread, plus quick shapes (fist, point, peace, open, claw).
- **Face**: every shape key on the model, with quick buttons for smile, wink, blink and mouth.
- **Animate**: keyframe timeline with easing and looping, preset animations (idle, sly idle, wave, fighting bounce, high kick, spin kick, walk, jump and land), save and reload, export as `.glb` with the animation baked in, or as `.json`.
- Mirror a pose, save your own poses, undo and redo, anime toon shading with outlines, backdrops, and picture export.

Preset poses are written in a body-relative frame, so they work on any humanoid skeleton the app can recognise:
Unity/3ds Max (`Bip001 L UpperArm`), MMD (`左腕`, `左ひじ`), Mixamo, VRM and Rigify-style names. If a bone is missed,
open **Scene → Fix bone matching** and pick it from the list.

## Getting your model in

Mobile apps cannot read `.blend` files directly. Convert once:

1. Open the `.blend` in Blender.
2. **File → External Data → Pack Resources** (so textures go inside).
3. **File → Export → glTF 2.0**, format **glTF Binary (.glb)**. Tick *Include → Custom Properties* off, *Data → Shape Keys* on, *Animation* off unless you want it.
4. Copy the `.glb` to your phone and tap **Choose model** in the app.

Model files are git-ignored. You can also drop `model.glb` into `public/models/` before building to ship it inside your own copy of the app.

## Run and build

```bash
npm install
npm run dev          # browser preview at http://localhost:5173
npm run build        # web bundle in dist/
npx cap sync         # copy it into the Android and iOS projects
```

**Android:** `npm run android` opens Android Studio; or `cd android && ./gradlew assembleDebug` and install
`android/app/build/outputs/apk/debug/app-debug.apk`.

**iOS:** needs a Mac with Xcode. `npm run ios` opens Xcode; pick your team under *Signing & Capabilities* and run on your iPhone.

**Without a computer:** every push runs `.github/workflows/build.yml`, which builds the Android APK and an unsigned iOS `.ipa`.
Download them from the workflow run's *Artifacts*. The unsigned `.ipa` must be signed before it installs
(for example with AltStore or Sideloadly using your Apple ID).

## Code map

| File | What it does |
| --- | --- |
| `src/rig.js` | Bone name detection, the body-relative pose math, finger curls, two-bone IK, mirroring |
| `src/poses.js` | Preset poses and preset animations |
| `src/timeline.js` | Keyframes, interpolation, export to an animation clip |
| `src/face.js` | Shape keys and their common names |
| `src/main.js` | Viewer, touch selection, gizmos, panels |
| `src/storage.js` | Keeps the model, poses and animations on the device; share-sheet export |

# Rigging a character on iPad

## 1. Prepare and import artwork

Split the character into layers in your painting app the way you want them to
move: face, each eye (white, iris, lashes, lids), brows, mouth (lips, inside),
front/side/back hair strands, neck, body, arms, clothing pieces, accessories.
Paint hidden areas (the face under the hair, the inside of the mouth) so movement
doesn't reveal holes. Groups are kept and become **parts**.

**Import PSD…** shows options: outline-following meshes and their vertex spacing,
and whether to add the standard parameters (Angle X/Y/Z, Eye L/R Open, Eyeball
X/Y, Brows, Mouth, Body, Breath, Hair). Clipping layers become clipping masks.

Later, **Update Artwork from PSD…** swaps in repainted layers (matched by
Photoshop layer id, then name) without touching the rig.

## 2. Refine meshes

Select a layer, then in the **Inspector → Mesh** section:

* **Auto Mesh** with a spacing (smaller = denser). Use denser meshes for parts
  that bend (mouth, eyelids, hair tips).
* **Edit Mesh** tool: tap inside to add a vertex, drag vertices to move them
  over the artwork, lasso and **Delete Vertices** to remove.
* **Triangles** tool: tap three vertices to make a triangle, tap inside one to
  delete it. **Subdivide** densifies around selected vertices; **Retriangulate**
  rebuilds triangles over the existing vertices.

## 3. Build the deformer tree

In **Deformers**, select layers or parts and add:

* a **warp deformer** for smooth bending (head turn, cheeks, hair sway, cloth), or
* a **rotation deformer** for pivoting (head tilt, arms, accessories). Drag its
  ring in Rig mode to place the pivot.

Selecting deformers together with layers wraps them too, so you can nest:
*Body Rotation → Head Rotation → Head Warp → Hair Front Sway*. Drag rows onto a
deformer, or use the row menu, to re-parent.

## 4. Parameters and keyforms

1. Select the objects to rig.
2. In **Parameters**, drag a slider to a value and tap **◇+** to add a key for
   the selection there (it binds the parameter if needed). Diamonds on the slider
   show existing keys; the slider snaps to them.
3. With the parameter on a key, deform: **Deform** tool on vertices or lattice
   points (lasso several; set a soft-selection radius in the Inspector), the
   **Rotate** tool or handle tip for rotation deformers, or the Inspector for
   opacity, draw order, angle and scale.
4. Move to another key and repeat. Between keys everything interpolates.

Objects can be bound to several parameters (e.g. Head Warp to Angle X *and*
Angle Y gives a 3×3 grid of shapes — set the corners too for convincing
diagonals). **Mirror Shape to Opposite Key** copies a left turn to the right.

## 5. Physics

**Physics → +** adds a group; the **Hair Preset** wires head/body sway as inputs
and your chosen parameter as output. Bind that output parameter to a sway warp
(bottom rows bend more than the top). Tune length, stiffness, damping and
follow-through while the preview runs.

## 6. Animate

Switch to **Animate**. Create a clip (or **Generate Idle Loop**), move the
playhead, and drag parameters — with auto-key (●) on, keys are written at the
playhead. Use **Key** to key every changed parameter. In the timeline: drag
diamonds to retime, long-press for interpolation, mute tracks, make tracks
additive (good for expressions layered over an idle), and open the curve editor
to shape bezier handles. Loop, once or ping-pong per clip.

## 7. Export

**Export** offers GIF, PNG sequence, transparent HEVC or ProRes 4444 video, opaque
H.264, a still, or the `.m2rt` runtime package. Crop-to-character and 2×
supersampling are on by default.

## Input reference

| Input | Action |
| --- | --- |
| Pencil / one finger | Active tool (fingers disabled with *Pencil Only Editing*) |
| Two fingers | Pan and pinch-zoom (cancels a stroke that just started) |
| Two-finger double tap | Fit canvas |
| Pencil double tap | Toggle between the last two tools |
| Pencil hover | Highlights the vertex that would be picked |
| Shift + tap (keyboard) | Add to / toggle selection |
| ⌘Z / ⇧⌘Z, three-finger swipe | Undo / redo |
| Space | Play / pause (Animate mode) |

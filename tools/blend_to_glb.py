"""Export a rigged character from a .blend to a .glb that Move2D can open.

In Blender: Scripting tab -> Open -> this file -> Run Script. The .glb is written next to the .blend.
Command line: blender -b character.blend -P blend_to_glb.py -- out.glb

What it does (your .blend is never saved or changed on disk):
- finds the armature that most meshes are skinned to and exports only its deform bones
  (works for Rigify rigs, where the deform bones are the DEF- ones),
- exports the meshes skinned to that armature that are visible in the viewport, so show the outfit
  you want and hide the rest before running,
- keeps shape keys (face expressions) and mutes their drivers so they export at rest,
- removes Geometry Nodes/outline modifiers in memory (they block skinning; the app draws its own outline),
- swaps custom/toon shaders, which glTF cannot carry, for a plain material using the base colour
  texture, so the model is not exported grey.
"""
import bpy, os, sys

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
out = argv[0] if argv else os.path.splitext(bpy.data.filepath)[0] + '.glb'
MAX_TEX = 2048

def skinned_to(o):
    return [m.object for m in o.modifiers if m.type == 'ARMATURE' and m.object]

counts = {}
for o in bpy.data.objects:
    if o.type == 'MESH':
        for a in skinned_to(o):
            counts[a] = counts.get(a, 0) + 1
if not counts:
    raise SystemExit('No skinned meshes found.')
arm = max(counts, key=counts.get)
meshes = [o for o in bpy.data.objects if o.type == 'MESH' and arm in skinned_to(o) and o.visible_get()]
print(f'Armature: {arm.name}  meshes: {[m.name for m in meshes]}')

# Rigify-style rigs hang deform bones off ORG/MCH bones, so a deform-only export loses the links
# between body parts (fingers would not follow the hand, arms not the chest). Re-parent each such
# deform bone to the deform twin of its nearest ORG- ancestor (ORG-Hand_L -> DEF-Hand_L), or else
# to its nearest deform ancestor. In memory only.
def relink_deform_bones(arm):
    bpy.context.view_layer.objects.active = arm
    arm.hide_set(False)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    deform = {b.name for b in eb if b.use_deform}
    def twin(name):
        for pre in ('ORG-', 'ORG_', 'MCH-'):
            if name.startswith(pre):
                for dpre in ('DEF-', 'DEF_'):
                    if dpre + name[len(pre):] in deform:
                        return dpre + name[len(pre):]
        return None
    changed = 0
    for b in [b for b in eb if b.use_deform]:
        if b.parent is None or b.parent.use_deform:
            continue
        p, target = b.parent, None
        while p is not None and target is None:
            t = p.name if p.use_deform else twin(p.name)
            if t and t != b.name:
                target = eb[t]
            p = p.parent
        if target is not None:
            b.use_connect = False
            b.parent = target
            changed += 1
    bpy.ops.object.mode_set(mode='OBJECT')
    print(f'Re-linked {changed} deform bones')

relink_deform_bones(arm)
arm.data.pose_position = 'REST'

# Geometry Nodes modifiers (outlines etc.) stop the exporter from writing the skin: drop them
# in memory. The app draws its own outline.
for o in meshes:
    for m in list(o.modifiers):
        if m.type not in ('ARMATURE',):
            o.modifiers.remove(m)

# Face expressions: mute drivers, zero the values.
for o in meshes:
    sk = o.data.shape_keys
    if sk and sk.animation_data:
        for d in sk.animation_data.drivers:
            d.mute = True
    if sk:
        for k in sk.key_blocks[1:]:
            k.value = 0.0

# Plain materials from the base colour texture.
def images_in(tree, seen=None):
    seen = seen or set()
    for n in tree.nodes:
        if n.type == 'TEX_IMAGE' and n.image:
            yield n.image
        elif n.type == 'GROUP' and n.node_tree and n.node_tree.name not in seen:
            seen.add(n.node_tree.name)
            yield from images_in(n.node_tree, seen)

def base_image(mat):
    if not mat or not mat.use_nodes:
        return None
    imgs = list(dict.fromkeys(images_in(mat.node_tree)))
    skip = ('matcap', 'lightmap', 'ramp', '_n.', '_n_', '_m.', '_a.', 'normal')
    for img in imgs:
        n = img.name.lower()
        if n.endswith(('_d.png', '_d')) or '_d.' in n or 'diffuse' in n or 'albedo' in n or 'basecolor' in n:
            return img
    for img in imgs:
        if not any(s in img.name.lower() for s in skip):
            return img
    return None

made = {}
def plain(mat):
    if mat is None or mat.name in made:
        return made.get(mat.name if mat else None)
    img = base_image(mat)
    m = bpy.data.materials.new(mat.name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
    bsdf.inputs['Roughness'].default_value = 0.8
    if img:
        if max(img.size) > MAX_TEX:
            img = img.copy(); img.scale(MAX_TEX, MAX_TEX)
        tex = nt.nodes.new('ShaderNodeTexImage'); tex.image = img
        nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    elif hasattr(mat, 'diffuse_color'):
        bsdf.inputs['Base Color'].default_value = mat.diffuse_color
    made[mat.name] = m
    return m

for o in meshes:
    for slot in o.material_slots:
        if slot.material:
            slot.material = plain(slot.material)

bpy.ops.object.mode_set(mode='OBJECT') if bpy.context.object and bpy.context.object.mode != 'OBJECT' else None
bpy.ops.object.select_all(action='DESELECT')
for o in [arm, *meshes]:
    o.hide_set(False)
    o.select_set(True)
bpy.context.view_layer.objects.active = arm

bpy.ops.export_scene.gltf(
    filepath=out, export_format='GLB', use_selection=True,
    export_def_bones=True, export_apply=False, export_morph=True, export_skins=True,
    export_animations=False, export_yup=True,
)
print('Wrote', out)

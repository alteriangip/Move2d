"""Run blend_to_glb.py on a .blend without opening Blender's UI.
Usage: python convert.py input.blend output.glb   (needs `pip install bpy`)"""
import os, runpy, sys
import bpy

src, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(os.path.dirname(out), exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=src, load_ui=False)
sys.argv = ['blend_to_glb.py', '--', out]
runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'blend_to_glb.py'))
if not os.path.exists(out):
    sys.exit('Export did not produce a file.')
print(f'OK {out} {os.path.getsize(out) / 1e6:.1f} MB')

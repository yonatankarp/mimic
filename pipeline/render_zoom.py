"""Close-up clay render of the top of a model, to judge small details.

    blender -b -P pipeline/render_zoom.py -- in.(glb|stl) out.png [--top 0.3] [--angle 180]

Scales the model to 100 units tall, frames the top --top fraction of it from --angle
degrees around (180 = the front of a Pixal3D figure).
"""

import argparse
import math
import sys

import bpy
from mathutils import Vector

a = argparse.ArgumentParser()
a.add_argument("model")
a.add_argument("png")
a.add_argument("--top", type=float, default=0.3)
a.add_argument("--angle", type=float, default=180)
a = a.parse_args(sys.argv[sys.argv.index("--") + 1:])

bpy.ops.wm.read_factory_settings(use_empty=True)
if a.model.endswith(".stl"):
    bpy.ops.wm.stl_import(filepath=a.model)
else:
    bpy.ops.import_scene.gltf(filepath=a.model)
objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
pts = [o.matrix_world @ v.co for o in objs for v in o.data.vertices]
lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
for o in objs:
    o.data.materials.clear()
    for poly in o.data.polygons:
        poly.use_smooth = True

s = bpy.context.scene
s.render.engine = "BLENDER_WORKBENCH"
s.display.shading.light = "STUDIO"
s.display.shading.color_type = "SINGLE"
s.display.shading.single_color = (0.75, 0.75, 0.75)
s.display.shading.show_cavity = True
s.render.resolution_x = s.render.resolution_y = 900
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.data.type = "ORTHO"
h = hi.z - lo.z
cam.data.ortho_scale = h * a.top * 1.1
s.collection.objects.link(cam)
s.camera = cam
mid = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z - h * a.top / 2))
r = math.radians(a.angle)
cam.location = mid + Vector((math.sin(r), -math.cos(r), 0)) * h * 3
cam.rotation_euler = (math.radians(90), 0, r)
cam.data.clip_end = h * 10
s.render.filepath = a.png
bpy.ops.render.render(write_still=True)

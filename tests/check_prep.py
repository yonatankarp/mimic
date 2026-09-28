"""Blender half of tests/test_prep.sh.

    blender -b -P tests/check_prep.py -- fixture out.glb
    blender -b -P tests/check_prep.py -- check out.stl

The fixture carries every defect mini_prep.py exists to fix, each one seen in a real run:
a floating speck, a paper-thin blade, a figure off the origin, and a wisp trailing below
the feet (the tiefling's robe, which once stood the whole figure on a pin).
"""

import math
import sys

import bmesh
import bpy

mode, path = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)

if mode == "fixture":
    off = (0.8, -0.5, 0)  # nowhere near the origin
    add = lambda op, loc, **kw: op(location=tuple(o + l for o, l in zip(off, loc)), **kw)
    add(bpy.ops.mesh.primitive_cylinder_add, (0, 0, 1), radius=0.35, depth=2)       # body, feet at z=0
    add(bpy.ops.mesh.primitive_uv_sphere_add, (0, 0, 2.3), radius=0.35)             # head
    add(bpy.ops.mesh.primitive_cube_add, (0.4, 0, 1.4), scale=(0.004, 0.08, 0.9))  # paper-thin blade
    add(bpy.ops.mesh.primitive_ico_sphere_add, (1.5, 0, 1.5), radius=0.04)          # floating speck
    add(bpy.ops.mesh.primitive_cylinder_add, (0, 0.45, 0.05), radius=0.03, depth=0.5,
        rotation=(0.6, 0, 0))                                                        # wisp below the feet
    bpy.ops.export_scene.gltf(filepath=path)
    sys.exit(0)

bpy.ops.wm.stl_import(filepath=path)
o = bpy.context.selected_objects[0]
bm = bmesh.new()
bm.from_mesh(o.data)
zs = [v.co.z for v in bm.verts]
lo, hi = min(zs), max(zs)
flat = sum(f.calc_area() for f in bm.faces if all(abs(v.co.z - lo) < 1e-3 for v in f.verts))
# Where only the body exists: above the wisp (which reaches ~3 mm up) and below the blade
# (from ~6 mm). Ground sits 2 mm above the bottom: 3 mm base, feet sunk 0.6, 0.4 sliced off.
ground = lo + 2.0
body = [v.co for v in bm.verts if ground + 3.6 < v.co.z < ground + 5.6]
cx = sum(p.x for p in body) / len(body)
cy = sum(p.y for p in body) / len(body)
checks = {
    "watertight (no non-manifold edges)": sum(not e.is_manifold for e in bm.edges) == 0,
    f"flat bottom covers the 25 mm base ({flat:.0f} mm2)": flat > 0.95 * math.pi * 12.5 ** 2,
    f"height 32 + 3 - 0.6 - 0.4 = 34 mm ({hi - lo:.2f})": abs((hi - lo) - 34.0) < 0.3,
    f"body centred on the base ({cx:+.2f}, {cy:+.2f} mm)": math.hypot(cx, cy) < 0.5,
}
# Count loose parts last: separating them rewrites the mesh the checks above read.
bpy.context.view_layer.objects.active = o
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.separate(type="LOOSE")
bpy.ops.object.mode_set(mode="OBJECT")
parts = len(bpy.context.selected_objects)
checks[f"one piece, speck removed ({parts} part(s))"] = parts == 1
for name, ok in checks.items():
    print(("PASS " if ok else "FAIL ") + name)
sys.exit(0 if all(checks.values()) else 1)

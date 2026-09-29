"""Turn a generated GLB into a printable mini STL, plus preview renders.

    blender -b -P pipeline/mini_prep.py -- in.glb out.stl [--height 32] [--base 25]
        [--base-height 3] [--nozzle 0.4] [--inflate MM] [--voxel MM] [--faces 800000]
        [--no-base] [--flatten 0.4]

Units are millimetres. Steps: join meshes, scale to --height, inflate the surface
by --inflate (thickens blades/staffs by twice that), stand it on a round base,
voxel-remesh everything into one watertight solid, slice the bottom flat, export STL, render
front/side/back PNGs next to the STL.
"""

import argparse
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
p = argparse.ArgumentParser()
p.add_argument("glb")
p.add_argument("stl")
p.add_argument("--height", type=float, default=32.0, help="figure height, feet to top, mm")
p.add_argument("--base", type=float, default=25.0, help="base diameter, mm")
p.add_argument("--base-height", type=float, default=3.0)
p.add_argument("--nozzle", type=float, default=0.4, help="printer nozzle, mm; sets --inflate")
p.add_argument("--inflate", type=float, default=None,
               help="surface offset, mm (default 0.4 x nozzle: 0.08 keeps a 0.2 nozzle's cloth whole)")
p.add_argument("--voxel", type=float, default=None,
               help="remesh voxel size, mm (default nozzle / 4); finer keeps detail, --faces trims the result")
p.add_argument("--no-base", action="store_true", help="keep the model's own base")
p.add_argument("--flatten", type=float, default=0.4, help="slice this much off the bottom, mm")
p.add_argument("--faces", type=int, default=800_000, help="decimate to about this many triangles")
a = p.parse_args(argv)
if a.inflate is None:
    # A wider nozzle drops thinner walls, so thin parts need more help to survive the slicer.
    # 0.4 x nozzle was tuned on a 0.2 nozzle (0.08 mm); 0.15 there already looked melted.
    a.inflate = round(0.4 * a.nozzle, 3)
if a.voxel is None:
    # A quarter of the nozzle: finer than any printer line, and never finer than that line
    # can show. A fixed 0.05 mm, tuned on a 0.2 nozzle, made a 100 mm figure on a 0.4 nozzle
    # remesh ~10x the faces and sit in Blender for many minutes using 8 GB.
    a.voxel = round(a.nozzle / 4, 3)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=a.glb)

meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not meshes:
    sys.exit(f"no mesh in {a.glb}")
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
fig = bpy.context.view_layer.objects.active
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
fig.data.materials.clear()


def bounds(obj):
    pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    return (Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts))),
            Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts))))


def remesh(obj, voxel):
    m = obj.modifiers.new("remesh", "REMESH")
    m.mode = "VOXEL"
    m.voxel_size = voxel
    m.adaptivity = 0
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=m.name)


def rescale(s):
    fig.scale = (s, s, s)
    bpy.ops.object.transform_apply(scale=True)


# Rough scale, then remesh: that closes the generator's holes, gives the inflate
# consistent normals, and makes vertex density even, so vertex counts below measure area.
lo, hi = bounds(fig)
rescale(a.height / (hi.z - lo.z))
remesh(fig, a.voxel)

# Ground is where most of the bottom is, not the lowest vertex: a trailing wisp or
# hanging tassel is a sliver of the surface below the 0.5th percentile, and ends up
# sunk into the base instead of holding the figure up on a pin.
zs = sorted(v.co.z for v in fig.data.vertices)
ground = zs[len(zs) // 200]
s = a.height / (bounds(fig)[1].z - ground)
rescale(s)
ground *= s

def section(z):
    """Area and area centroid of the solid's horizontal cross-section at height z."""
    bm = bmesh.new()
    bm.from_mesh(fig.data)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:],
                           plane_co=(0, 0, z), plane_no=(0, 0, 1), clear_outer=True)
    bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary])
    area = cx = cy = 0.0
    for f in bm.faces:
        if all(abs(v.co.z - z) < 1e-4 for v in f.verts):
            fa, c = f.calc_area(), f.calc_center_median()
            area, cx, cy = area + fa, cx + fa * c.x, cy + fa * c.y
    bm.free()
    return area, cx, cy


# Centre on what the figure stands on: the solid cross-sections through its lower body.
# Not a box, which a raised weapon or a trailing wisp stretches by its whole length, and
# not the surface vertices, which count a thin wisp's skin as heavily as a leg's: on the
# fixture in tests/ those were off by 2.0 mm (box) and 0.65 mm (vertex mean).
cuts = [section(ground + f * a.height) for f in (0.03, 0.06, 0.09, 0.12)]
total = sum(c[0] for c in cuts) or 1
fx = sum(c[1] for c in cuts) / total
fy = sum(c[2] for c in cuts) / total
foot = [v.co.copy() for v in fig.data.vertices if ground <= v.co.z <= ground + 0.15 * a.height]
fig.location -= Vector((fx, fy, ground))
bpy.ops.object.transform_apply(location=True)
footprint = 2 * max(math.hypot(p.x - fx, p.y - fy) for p in foot)

if a.inflate > 0:
    d = fig.modifiers.new("inflate", "DISPLACE")
    d.direction = "NORMAL"
    d.mid_level = 0
    d.strength = a.inflate
    bpy.ops.object.modifier_apply(modifier=d.name)

if not a.no_base:
    # Sink the feet 0.6 mm into the base so the union is solid.
    fig.location.z = a.base_height - 0.6
    bpy.ops.object.transform_apply(location=True)
    bpy.ops.mesh.primitive_cylinder_add(vertices=128, radius=a.base / 2,
                                        depth=a.base_height,
                                        location=(0, 0, a.base_height / 2))
    base = bpy.context.active_object
    # Bevel the top edge like a commercial base.
    bev = base.modifiers.new("bevel", "BEVEL")
    bev.width = min(0.6, a.base_height / 3)
    bev.segments = 3
    bpy.ops.object.modifier_apply(modifier=bev.name)
    bpy.ops.object.select_all(action="DESELECT")
    fig.select_set(True)
    base.select_set(True)
    bpy.context.view_layer.objects.active = fig
    bpy.ops.object.join()

remesh(fig, a.voxel)  # one watertight solid, figure fused to base

# Keep only the largest connected piece: drops floating specks the generator left.
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.separate(type="LOOSE")
bpy.ops.object.mode_set(mode="OBJECT")
parts = sorted(bpy.context.selected_objects, key=lambda o: len(o.data.vertices), reverse=True)
fig, extras = parts[0], parts[1:]
for o in extras:
    bpy.data.objects.remove(o)
bpy.context.view_layer.objects.active = fig
fig.select_set(True)

# Slice the bottom flat so it sits on the bed: generated bases carry bumps underneath.
if a.flatten > 0:
    cut = a.flatten  # z=0 is the base's underside (or the ground with --no-base); anything below goes
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.bisect(plane_co=(0, 0, cut), plane_no=(0, 0, 1),
                        clear_inner=True, use_fill=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    fig.location.z -= cut
    bpy.ops.object.transform_apply(location=True)

# A fine voxel keeps detail but makes millions of faces; collapsing a dense, even mesh
# back down loses nothing a 0.2 mm nozzle can print and keeps the STL openable.
tris = sum(len(p.vertices) - 2 for p in fig.data.polygons)
if tris > a.faces:
    dec = fig.modifiers.new("decimate", "DECIMATE")
    dec.ratio = a.faces / tris
    bpy.ops.object.modifier_apply(modifier=dec.name)

bpy.ops.object.shade_smooth()
bpy.ops.object.select_all(action="DESELECT")
fig.select_set(True)
# Written beside it and renamed into place: a resize stopped mid-export keeps the old print file
# whole instead of leaving half of a new one. The name ends in .stl, or the exporter appends one.
part = a.stl[:-4] + ".part.stl" if a.stl.endswith(".stl") else a.stl + ".part.stl"
bpy.ops.wm.stl_export(filepath=part, export_selected_objects=True, apply_modifiers=True)
os.replace(part, a.stl)

lo, hi = bounds(fig)
print(f"mini_prep: {a.stl}  size {hi.x-lo.x:.1f} x {hi.y-lo.y:.1f} x {hi.z-lo.z:.1f} mm  "
      f"faces {len(fig.data.polygons)}  loose pieces dropped {len(extras)}  footprint {footprint:.1f} mm")
if not a.no_base and footprint > a.base:
    print(f"mini_prep: WARNING footprint {footprint:.1f} mm is wider than the {a.base:.0f} mm base; "
          f"raise the base to at least {math.ceil(footprint + 1)} mm")

# Preview renders: grey clay, three angles.
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "SINGLE"
scene.display.shading.single_color = (0.75, 0.75, 0.75)
scene.display.shading.show_cavity = True
scene.render.resolution_x = scene.render.resolution_y = 900
scene.render.film_transparent = False
cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(hi.z - lo.z, hi.x - lo.x, hi.y - lo.y) * 1.15
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
mid = (lo + hi) / 2
# Pixal3D figures face +Y after import.
for name, ang in (("front", 180), ("side", 90), ("back", 0)):
    r = math.radians(ang)
    cam.location = mid + Vector((math.sin(r) * 200, -math.cos(r) * 200, 0))
    cam.rotation_euler = (math.radians(90), 0, r)
    scene.render.filepath = a.stl.rsplit(".", 1)[0] + f"_{name}.png"
    bpy.ops.render.render(write_still=True)

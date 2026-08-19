"""Post-bake fixup: re-project each surface's attenuation falloff over its own depth.

Apple's tool projects the attenuation mask over exactly one dock-width for every surface. The
official captures show each surface wants its own reach:
- Ceiling: the up-looking A/B in `Draft 5/` reads pure black for 87% of Apple's frame with a
  faint glow only at the screen edge, so the ceiling dies even sooner than the floor -> 0.75x.
- Floor: the pool dies about halfway to the viewer (head-down A/B in `Draft 3/`, where Apple's
  near floor reads 0x00-0x01 against our 0x1b-0x22) -> 0.63x, putting the band's dark edge at
  ~0.55 dock-widths out.

Only attenuationUVs are rewritten; emitter UVs stay exactly as the tool baked them.

Usage: adjust_attenuation_spans.py <baked.usda> <dockZ> <dockWidth>
"""
import sys
from pxr import Usd, UsdGeom, Gf

# The attenuation texture measurements for Reality Composer Pro's default map, from Apple's tool.
V_START, V_END = 0.097, 0.5
SPAN_FACTORS = {"Lightspill_Ceiling": 0.75, "Lightspill_Floor": 0.63}

path, dock_z, width = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
stage = Usd.Stage.Open(path)
seen = set()
for prim in stage.Traverse():
    if not prim.IsA(UsdGeom.Mesh) or prim.GetName() not in SPAN_FACTORS:
        continue
    seen.add(prim.GetName())
    span = width * SPAN_FACTORS[prim.GetName()]

    mesh = UsdGeom.Mesh(prim)
    xform = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    points = [xform.Transform(p) for p in mesh.GetPointsAttr().Get()]

    pv = UsdGeom.PrimvarsAPI(prim).GetPrimvar("attenuationUVs")
    uvs = pv.Get()
    assert len(uvs) == len(points)

    new_uvs = []
    for p, uv in zip(points, uvs):
        t = (p[2] - dock_z) / span
        v = 1.0 - (t * (V_END - V_START) + V_START)
        # Both extremes of the texture are black; clamp so an out-of-range v can never wrap
        # back into the bright band if the sampler repeats.
        v = min(max(v, 0.0), 1.0)
        new_uvs.append(Gf.Vec2f(uv[0], v))
    pv.Set(new_uvs)
    vs = [uv[1] for uv in new_uvs]
    print(f"  {prim.GetName()}: attenuation v [{min(vs):.3f}, {max(vs):.3f}]")

assert seen == set(SPAN_FACTORS), f"missing surfaces: {set(SPAN_FACTORS) - seen}"
stage.GetRootLayer().Save()

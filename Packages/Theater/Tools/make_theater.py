"""Generates the Theater environment's USD scene: light-spill surfaces, the material that
carries RealityKit's video-reflection nodes, and the docking region the video lands in.

Run once per seat. The output still needs Apple's computeDiffuseReflectionUVs.py run over it to
bake the emitter/attenuation UVs the diffuse node reads.
"""
import pathlib
import re
import sys
from pxr import Usd, UsdGeom, UsdShade, Sdf, Gf

# Matches TheaterSeat.layout on the Swift side.
SEATS = {
    "Front":  dict(distance=6.8,  centerY=3.0,  width=13.0, floorY=-0.4, ceilingY=6.2),
    "Middle": dict(distance=10.2, centerY=2.35, width=11.5, floorY=-0.9, ceilingY=5.8),
    # The back row is the balcony: elevated, looking down at the screen — IMG_0086's pill reads
    # "Dernier rang" over exactly this geometry. Same screen as the middle row, so the same dock
    # width; the viewer is up near the ceiling and the main floor is far below the screen.
    "Back":   dict(distance=14.5, centerY=-0.9, width=11.5, floorY=-4.2, ceilingY=2.9),
}

# The reference recordings put the ceiling at roughly 0.4x the picture's own brightness and the
# specular gloss far below that. Studio uses 0.294 / 0.0235; the ceiling here reads a little
# hotter than Studio's floor because it is closer to square-on with the screen.
# The material is Destination Video's own, copied whole from its Floor.usda into
# LightSpillMaterial.usda. It is the reference implementation of RealityKit's video reflections;
# an equivalent graph authored by hand evaluated to zero. Tune the look through the per-surface
# gains below, not by rewriting the graph.
#
# Ceiling and floor take the screen's light differently — the reference frame puts the ceiling
# pool at 0.33x the screen's luminance and the floor at 0.22x — so each surface gets its own
# copy of the material with its own diffuse gain. Calibrated against the identical frame docked
# in both environments.
DIFFUSE_GAINS = {"Ceiling": 2.2, "Floor": 3.5}


def add_plane(stage, path, centre, u_axis, v_axis, u_size, v_size, segments, normal):
    """A subdivided quad. Density matters: the emitter UVs are per-vertex, so a coarse plane
    would step the spill instead of grading it."""
    mesh = UsdGeom.Mesh.Define(stage, path)
    points, sts, normals = [], [], []
    for j in range(segments + 1):
        for i in range(segments + 1):
            fu = i / segments - 0.5
            fv = j / segments - 0.5
            p = (Gf.Vec3f(*centre)
                 + Gf.Vec3f(*u_axis) * (fu * u_size)
                 + Gf.Vec3f(*v_axis) * (fv * v_size))
            points.append(p)
            sts.append(Gf.Vec2f(i / segments, j / segments))
            normals.append(Gf.Vec3f(*normal))

    # Wind each quad so its geometric front matches the requested normal: the light-spill
    # shading only lands on the geometric front face, whatever the authored normals claim.
    # (This is why the floor stayed black while a correctly-wound wall glowed.)
    u, v, n = u_axis, v_axis, normal
    cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
    flip = (cross[0] * n[0] + cross[1] * n[1] + cross[2] * n[2]) < 0

    counts, indices = [], []
    for j in range(segments):
        for i in range(segments):
            a = j * (segments + 1) + i
            b = a + 1
            c = a + segments + 2
            d = a + segments + 1
            counts.append(4)
            indices.extend([a, d, c, b] if flip else [a, b, c, d])

    mesh.CreatePointsAttr(points)
    mesh.CreateFaceVertexCountsAttr(counts)
    mesh.CreateFaceVertexIndicesAttr(indices)
    mesh.CreateNormalsAttr(normals)
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    mesh.CreateSubdivisionSchemeAttr("none")
    mesh.CreateDoubleSidedAttr(True)

    primvars = UsdGeom.PrimvarsAPI(mesh)
    # Apple's material samples its base texture through a primvar of this name. The texture is
    # empty here — the room is black except where the screen reaches it — but the reader still
    # has to find the channel.
    for name in ("st", "UVChannel_1"):
        primvars.CreatePrimvar(name, Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex).Set(sts)

    # Matches how Destination Video marks its own light-spill geometry.
    understanding = stage.DefinePrim(f"{path}/SceneUnderstanding", "RealityKitComponent")
    understanding.CreateAttribute("info:id", Sdf.ValueTypeNames.Token, True).Set("RealityKit.SceneUnderstanding")
    return mesh


def add_docking_region(stage, path, centre, width):
    """Where the system puts the video. Everything else in the room is positioned around it."""
    xform = UsdGeom.Xform.Define(stage, path)
    xform.AddTranslateOp().Set(Gf.Vec3d(*centre))

    # The encoding Reality Composer Pro writes, taken from Destination Video rather than guessed:
    # a bounds struct at the fixed 2.4:1 dock aspect.
    component = stage.DefinePrim(f"{path}/CustomDockingRegion", "RealityKitComponent")
    component.CreateAttribute("info:id", Sdf.ValueTypeNames.Token, True).Set("RealityKit.CustomDockingRegion")
    bounds = stage.DefinePrim(f"{path}/CustomDockingRegion/m_bounds", "RealityKitStruct")
    half_w, half_h = width / 2, width / (2 * 2.4)
    bounds.CreateAttribute("max", Sdf.ValueTypeNames.Float3).Set(Gf.Vec3f(half_w, half_h, 0))
    bounds.CreateAttribute("min", Sdf.ValueTypeNames.Float3).Set(Gf.Vec3f(-half_w, -half_h, 0))
    return xform


def build(seat, out_path):
    layout = SEATS[seat]
    distance, width = layout["distance"], layout["width"]

    stage = Usd.Stage.CreateInMemory(out_path)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1)
    root = UsdGeom.Xform.Define(stage, "/Root")
    stage.SetDefaultPrim(root.GetPrim())

    materials = {}
    for name, gain in DIFFUSE_GAINS.items():
        path = f"/Root/Materials/{name}Spill"
        prim = stage.DefinePrim(path)
        prim.GetReferences().AddReference("./LightSpillMaterial.usda", "/Root/LightSpill")
        material = UsdShade.Material.Get(stage, path)
        assert material, f"the light-spill material failed to compose for {name}"
        # Override the diffuse gain on this copy; everything else stays Apple's.
        gain_shader = UsdShade.Shader.Get(stage, f"{path}/Constant_2")
        gain_shader.GetInput("value").Set(Gf.Vec3f(gain, gain, gain))
        materials[name] = material

    # The lit surfaces run from just behind the screen back past the viewer, and are only as wide
    # as the light actually reaches. Beyond them is nothing, which in full immersion is black.
    # Deep enough to run from behind the screen to well past the viewer, and wide enough that
    # the attenuation mask fades to black before the mesh edge — a lit surface ending in a hard
    # seam was draft 1's ugliest artifact on device.
    # Deep enough to run from behind the screen to past the balcony's back row (eye at
    # z=+7.2), wide enough that the attenuation mask fades to black before the mesh edge.
    span = distance + 13
    half_width = width * 2.5
    centre_z = (9 - distance) / 2

    surfaces = [
        ("Ceiling", (0, layout["ceilingY"], centre_z), (1, 0, 0), (0, 0, 1), half_width * 2, span, 40, (0, -1, 0)),
        ("Floor", (0, layout["floorY"], centre_z), (1, 0, 0), (0, 0, 1), half_width * 2, span, 40, (0, 1, 0)),
    ]

    # Grouped the way Destination Video groups its own, under a proxy-mesh scope.
    UsdGeom.Xform.Define(stage, "/Root/SystemProxyMesh")
    for name, centre, u_axis, v_axis, u_size, v_size, segments, normal in surfaces:
        mesh = add_plane(stage, f"/Root/SystemProxyMesh/Lightspill_{name}",
                         centre, u_axis, v_axis, u_size, v_size, segments, normal)
        UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(materials[name])

    add_docking_region(stage, "/Root/Player", (0, layout["centerY"], -distance), width)

    reverb = stage.DefinePrim("/Root/Reverb/Reverb", "RealityKitComponent")
    reverb.CreateAttribute("info:id", Sdf.ValueTypeNames.Token, True).Set("RealityKit.Reverb")
    reverb.CreateAttribute("reverbPreset", Sdf.ValueTypeNames.Token).Set("REAudioReverbPresetLargeRoom")

    # Flatten before saving: the .rkassets compiler mishandles cross-file references to a
    # non-default prim (USD composes them perfectly; the compiled scene renders the material
    # black), so each seat ships self-contained — which is also how Apple's own environments
    # arrive, as single compiled scenes.
    flat = stage.Flatten()
    text = flat.ExportToString()
    # Flattening anchors asset paths absolutely; put them back relative to the .rkassets root.
    text = re.sub(r'@[^@]*/textures/', '@textures/', text)
    pathlib.Path(out_path).write_text(text)
    print(f"{seat}: dock (0, {layout['centerY']}, {-distance}) width {width}")


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])

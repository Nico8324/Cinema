#!/bin/zsh
# Rebuilds the Theater asset pipeline end to end into $WORK (default: a temp dir).
# Usage: setup_and_bake.sh [workdir]
set -e
TOOLS="$(cd "$(dirname "$0")" && pwd)"
RKASSETS="$TOOLS/../Sources/Theater/Theater.rkassets"
WORK="${1:-$(mktemp -d)}"
cd "$WORK"

if [ ! -x venv/bin/python ]; then
  python3 -m venv venv
  venv/bin/pip -q install usd-core
fi

APPLE_TOOL="WWDC_2024_Diffuse_Reflection_UV_Computation_Tool/computeDiffuseReflectionUVs.py"
if [ ! -f "$APPLE_TOOL" ]; then
  curl -sSL -o tool.zip "https://developer.apple.com/sample-code/ar/WWDC_2024_Diffuse_Reflection_UV_Computation_Tool.zip"
  unzip -o -q tool.zip
  # Current USD: Transform() returns Vec3d, which no longer coerces into the Vec3fArray in place.
  venv/bin/python - "$APPLE_TOOL" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = """        for i in range(len(positions)):
            positions[i] = localToWorld.Transform(positions[i])"""
new = "        positions = [Gf.Vec3f(localToWorld.Transform(position)) for position in positions]"
if old in s: p.write_text(s.replace(old, new))
PY
fi

cp "$RKASSETS/LightSpillMaterial.usda" .
venv/bin/python "$TOOLS/make_theater.py" Middle raw_Middle.usda
venv/bin/python "$APPLE_TOOL" raw_Middle.usda -o baked_Middle.usda -p / -r true \
  --onlyWithSubstring Lightspill -x 0 -y 2.35 -z -10.2 -w 14.0 \
  -e primvars:emitterUVs -a primvars:attenuationUVs -s 1000 -v false
venv/bin/python "$TOOLS/adjust_attenuation_spans.py" baked_Middle.usda -10.2 14.0
cp baked_Middle.usda "$RKASSETS/TheaterMiddle.usda"
echo "BAKED -> $RKASSETS/TheaterMiddle.usda (work: $WORK)"

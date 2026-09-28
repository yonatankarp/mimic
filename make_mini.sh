#!/usr/bin/env bash
# Character description -> printable STL, in runs/<name>/.
#
#   ./make_mini.sh dwarf-cleric "dwarf cleric, warhammer held against chest, shield on back"
#   SEED=7 ./make_mini.sh ...        # another take on the same description
#   ./make_mini.sh name --image my.png   # skip image generation, use your own picture
#   ./make_mini.sh name --image art.png --restyle   # redraw it as a grey sculpt first (paintings, photos)
#   extra flags after the description go to mini_prep.py, e.g. --height 50 --base 32
#
# Needs Draw Things running with its HTTP API server on 127.0.0.1:7860.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$HERE/image-to-3dlab"
name="$1"; shift
out="$HERE/runs/$name"
mkdir -p "$out"
seed="${SEED:-42}"

if [ "${1:-}" = "--image" ]; then
  src="$2"; shift 2
  if [ "${1:-}" = "--restyle" ]; then
    shift
    # Paintings and photos mesh badly: texture turns into bumps, dark-on-dark loses shapes.
    # FLUX.2 Klein edits at strength 1, redrawing the same character as a grey sculpt.
    echo "[1/3] restyle as a miniature sculpt (seed $seed)"
    cp "$src" "$out/original.img"
    # Draw Things wants width/height equal to the image's, in multiples of 64; long side 1536.
    read -r w h < <(sips -g pixelWidth -g pixelHeight "$src" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{
      s = 1536 / (w > h ? w : h); printf "%d %d\n", int(w*s/64+.5)*64, int(h*s/64+.5)*64}')
    sips -s format png -z "$h" "$w" "$src" --out "$out/restyle_in.png" >/dev/null
    base64 -i "$out/restyle_in.png" | tr -d '\n' > "$out/restyle_in.b64"
    edit="Turn this character into an unpainted grey plastic tabletop miniature sculpt. Keep the same character, pose, face, clothing, weapons and accessories. Clean sculpted forms, bold readable shapes, slightly larger head and hands, feet or hem resting on the ground, no base. Plain light grey studio background, soft even lighting, 3D render."
    jq -n --rawfile img "$out/restyle_in.b64" --arg p "$edit" --argjson s "$seed" --argjson w "$w" --argjson h "$h" \
        '{init_images:[$img], strength:1.0, prompt:$p, seed:$s, width:$w, height:$h}' \
      | curl -sf -m 900 http://127.0.0.1:7860/sdapi/v1/img2img -H 'Content-Type: application/json' -d @- \
      | jq -r '.images[0]' | base64 -d > "$out/source.png"
    rm -f "$out/restyle_in.b64"
  else
    cp "$src" "$out/source.png"
  fi
else
  desc="$1"; shift
  # Styled for FDM: compact pose, chunky shapes, no sculpted base (mini_prep adds one).
  prompt="full-body fantasy tabletop miniature of a $desc, heroic proportions, compact pose, limbs and weapons held close to the body, bold chunky details, entire figure visible from head to feet, standing on nothing, no base, no pedestal, front view, centered, plain light grey studio background, unpainted grey 3D render"
  echo "[1/3] image (seed $seed)"
  jq -n --arg p "$prompt" --argjson s "$seed" '{prompt:$p, seed:$s, width:1024, height:1024}' \
    | curl -sf -m 900 http://127.0.0.1:7860/sdapi/v1/txt2img -H 'Content-Type: application/json' -d @- \
    | jq -r '.images[0]' | base64 -d > "$out/source.png"
fi

echo "[2/3] mesh (Pixal3D, ~7 min)"
(cd "$LAB" && .venv/bin/python scripts/pixal3d_generate.py "$out/source.png" "$out/model.glb" --seed "$seed") \
  > "$out/pixal3d.log" 2>&1 || { tail -20 "$out/pixal3d.log"; exit 1; }

echo "[3/3] print prep"
blender -b -P "$HERE/pipeline/mini_prep.py" -- "$out/model.glb" "$out/$name.stl" "$@" 2>&1 | grep -E "^mini_prep|Error"
echo "done: $out/$name.stl  (+ ${name}_front/side/back.png)"

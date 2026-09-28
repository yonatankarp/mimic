#!/usr/bin/env bash
# End-to-end check of pipeline/mini_prep.py on a synthetic figure. Needs Blender, no GPU.
#   tests/test_prep.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

blender -b -P "$HERE/tests/check_prep.py" -- fixture "$tmp/fixture.glb" >/dev/null 2>&1
blender -b -P "$HERE/pipeline/mini_prep.py" -- "$tmp/fixture.glb" "$tmp/out.stl" 2>&1 | grep '^mini_prep'
blender -b -P "$HERE/tests/check_prep.py" -- check "$tmp/out.stl" 2>&1 | grep -E '^(PASS|FAIL)'

#!/usr/bin/env bash
# One-time setup on an Apple Silicon Mac. Safe to re-run: every step skips what is done.
#
#   ./setup.sh           # asks before the 8.4 GB model download
#   ./setup.sh --yes     # no questions
#
# Installs uv, jq and Blender with Homebrew, clones image-to-3dlab at a pinned release,
# builds Pixal3D for Metal and fetches its weights. Draw Things is set up by hand (README).
set -euo pipefail

LAB_REPO="https://github.com/Bingeljell/image-to-3dlab.git"
LAB_TAG="v0.3.4"   # the release this project was built and tested against
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$HERE/image-to-3dlab"
YES=()
[ "${1:-}" = "--yes" ] && YES=(--yes)

say() { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)/$(uname -m)" = "Darwin/arm64" ] || die "needs an Apple Silicon Mac"
command -v brew >/dev/null || die "needs Homebrew: https://brew.sh"
# Pixal3D compiles Metal kernels, which the Command Line Tools alone cannot do.
xcodebuild -version >/dev/null 2>&1 || die "needs full Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"

for f in uv jq; do command -v "$f" >/dev/null || { say "installing $f"; brew install "$f"; }; done
command -v blender >/dev/null || { say "installing Blender"; brew install --cask blender; }

if [ ! -d "$LAB/.git" ]; then
  say "cloning image-to-3dlab $LAB_TAG"
  git clone --quiet --branch "$LAB_TAG" --depth 1 "$LAB_REPO" "$LAB"
fi
say "installing the lab's Python environment"
bash "$LAB/install.sh" --yes --dir "$LAB" --ref "$LAB_TAG"

if [ ! -x "$LAB/vendor/pixal3d-cpp/build/trellis-cli" ] || [ ! -d "$LAB/vendor/pixal3d-cpp/models/pixal3d-sv" ]; then
  say "building Pixal3D and fetching its weights (8.4 GB)"
  (cd "$LAB" && .venv/bin/python scripts/bootstrap_pixal3d.py ${YES[@]+"${YES[@]}"})
fi

say "done. Remaining manual step: Draw Things (see README), then double-click 'Mini Forge.command'"

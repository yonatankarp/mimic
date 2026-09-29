#!/usr/bin/env bash
# Installs everything Mimic needs on an Apple Silicon Mac, and a Mimic app to open it.
# Safe to re-run: every step skips what is already there. Most people double-click
# "Install Mimic.command", which runs this.
#
#   ./setup.sh                      # asks once before the big downloads
#   ./setup.sh --yes                # no questions
#   ./setup.sh --build-from-source  # compile the 3D engine here (needs full Xcode)
set -euo pipefail

LAB_REPO="https://github.com/Bingeljell/image-to-3dlab.git"
LAB_TAG="v0.3.4"   # the release Mimic is built and tested against
# pixal3d.cpp d1b4926, built for macOS 14+ by tools/package_pixal3d.sh, so nobody needs Xcode.
PIXAL3D_URL="https://github.com/yonatankarp/mimic/releases/download/pixal3d-d1b4926/pixal3d-metal-d1b4926-macos14.0.tar.gz"
PIXAL3D_SHA256="58aa276c7605bddf250533c982ccd43c2e0791791b6cf2f5e2c777ff56c7dede"
# The app itself, built and zipped by tools/package_app.sh.
MIMIC_APP_URL="https://github.com/yonatankarp/mimic/releases/download/app-PENDING/Mimic-PENDING.zip"
MIMIC_APP_SHA256="PENDING"

HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$HERE/image-to-3dlab"
ENGINE="$LAB/vendor/pixal3d-cpp"
YES=0; SOURCE=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --build-from-source) SOURCE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
die()  { printf '\n\033[1;31m✋ %s\033[0m\n' "$*" >&2; exit 1; }

# --- Can this Mac run it? ------------------------------------------------------------------
[ "$(uname -m)" = arm64 ] || die "Mimic needs a Mac with an Apple chip (M1 or newer)."
version="$(sw_vers -productVersion)"
[ "${version%%.*}" -ge 15 ] || die "Mimic needs macOS 15 (Sequoia) or newer, and this Mac has $version. Update it in System Settings → General → Software Update, then run the installer again."
free_gb="$(df -g "$HERE" | awk 'NR==2 {print $4}')"
[ "$free_gb" -ge 25 ] || die "Mimic needs about 25 GB of free space, and this disk has $free_gb GB."

if [ "$YES" = 0 ]; then
  cat <<'TEXT'

🧰 This installs Mimic and everything it needs:
   • Homebrew (a standard installer for Mac tools), Blender and Draw Things
   • about 10 GB of AI models
   It takes 20–60 minutes, depending on your internet.
   Your Mac may ask for your password once.
TEXT
  read -r -p "Continue? [Y/n] " answer
  case "$answer" in n*|N*) exit 0 ;; esac
fi

# Files from a downloaded ZIP carry macOS's "downloaded from the internet" flag, which makes
# every double-click of Mimic.command ask again. They are this folder's own files.
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true

# --- Homebrew --------------------------------------------------------------------------------
step "Homebrew"
if [ ! -x /opt/homebrew/bin/brew ]; then
  # Homebrew's own signed .pkg, not a curl | bash script.
  pkg_url="$(curl -fsSL https://api.github.com/repos/Homebrew/brew/releases/latest | grep -o 'https://[^"]*\.pkg' | head -1)"
  [ -n "$pkg_url" ] || die "Couldn't find Homebrew's installer. Check the internet connection and try again."
  curl -fL --progress-bar -o "$TMPDIR/Homebrew.pkg" "$pkg_url"
  echo "  🔑 Your Mac password is needed to install Homebrew (nothing shows while you type it)."
  sudo installer -pkg "$TMPDIR/Homebrew.pkg" -target /
fi
# Homebrew's tools first in line: without Apple's developer tools, /usr/bin/git is only a
# stub that opens an install dialog and fails.
eval "$(/opt/homebrew/bin/brew shellenv)"
ok "Homebrew"

# --- Tools and apps --------------------------------------------------------------------------
step "Tools and apps"
for f in git uv; do brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"; done
[ -d /Applications/Blender.app ] || brew install --cask blender
[ -d "/Applications/Draw Things.app" ] || brew install --cask draw-things
ok "git, uv, Blender, Draw Things"

# --- The 3D engine ---------------------------------------------------------------------------
step "Mimic's 3D engine"
[ -d "$LAB/.git" ] || git clone --quiet --branch "$LAB_TAG" --depth 1 "$LAB_REPO" "$LAB"
bash "$LAB/install.sh" --yes --dir "$LAB" --ref "$LAB_TAG" >/dev/null
ok "image-to-3dlab $LAB_TAG"

if [ ! -x "$ENGINE/build/trellis-cli" ]; then
  if [ "$SOURCE" = 1 ]; then
    xcodebuild -version >/dev/null 2>&1 || die "Building from source needs full Xcode from the App Store."
    (cd "$LAB" && .venv/bin/python scripts/bootstrap_pixal3d.py --build-only --yes)
  else
    tarball="$TMPDIR/pixal3d-metal.tar.gz"
    curl -fL --progress-bar -o "$tarball" "$PIXAL3D_URL"
    echo "$PIXAL3D_SHA256  $tarball" | shasum -a 256 -c - >/dev/null \
      || die "The 3D engine download is damaged. Run the installer again."
    mkdir -p "$ENGINE/build"
    tar -xzf "$tarball" -C "$ENGINE/build" --strip-components=1
  fi
fi
"$ENGINE/build/trellis-cli" --help >/dev/null 2>&1 || die "The 3D engine doesn't start on this Mac."
ok "Pixal3D"

if [ ! -f "$ENGINE/models/pixal3d-sv/pixal3d_shape_flow_1024_sv.gguf" ]; then
  echo "  ⏳ Downloading the 3D model (8.4 GB). This is the long part."
  (cd "$LAB" && .venv/bin/python scripts/bootstrap_pixal3d.py --weights-only --yes)
fi
ok "3D model"

# --- The app ---------------------------------------------------------------------------------
step "The Mimic app"
app="$HOME/Applications/Mimic.app"
mkdir -p "$HOME/Applications"
zip="$TMPDIR/Mimic.zip"
curl -fL --progress-bar -o "$zip" "$MIMIC_APP_URL"
echo "$MIMIC_APP_SHA256  $zip" | shasum -a 256 -c - >/dev/null || die "The Mimic app download is damaged. Run the installer again."
rm -rf "$app"
ditto -x -k "$zip" "$HOME/Applications"
# Where this folder is: the app keeps its minis here, next to the 3D engine.
defaults write com.mimic.app installDir "$HERE"
# `mimic make …` in a terminal: the app's own binary, which has a command-line mode.
ln -sf "$app/Contents/MacOS/mimic" /opt/homebrew/bin/mimic
ok "Mimic is in your Applications folder ($app)"

printf '\n🎉 \033[1mAll set!\033[0m Opening Mimic. If anything is still missing, ⚙️ Settings in Mimic says what.\n'
open "$app"

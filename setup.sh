#!/usr/bin/env bash
# Installs everything Mimic needs on an Apple Silicon Mac, and a Mimic app to open it.
# Safe to re-run: every step skips what is already there. Most people double-click
# "Install Mimic.command", which runs this.
#
#   ./setup.sh        # asks once before the big downloads
#   ./setup.sh --yes  # no questions
set -euo pipefail

# pixal3d.cpp d1b4926, built for macOS 14+ by tools/package_pixal3d.sh, so nobody needs Xcode.
PIXAL3D_URL="https://github.com/yonatankarp/mimic/releases/download/pixal3d-d1b4926/pixal3d-metal-d1b4926-macos14.0.tar.gz"
PIXAL3D_VERSION="pixal3d.cpp d1b4926"   # how its VERSION file starts
PIXAL3D_SHA256="58aa276c7605bddf250533c982ccd43c2e0791791b6cf2f5e2c777ff56c7dede"
# The app itself, built and zipped by tools/package_app.sh.
MIMIC_APP_URL="https://github.com/yonatankarp/mimic/releases/download/app-6b921d4/Mimic-6b921d4.zip"
MIMIC_APP_SHA256="631fda60f0abca4d0dba9048b9c9cf416465dbd6b64f5d6ed364328742f1a584"
# Pixal3D's model files, from Hugging Face at a pinned revision, each checked against its sha256
# (the big ones are Hugging Face's own LFS hashes). The licences travel with the weights.
WEIGHTS_URL="https://huggingface.co/raven38/pixal3d-sv-q8_0-v1/resolve/46d399ac986f45a0d7f5b1ca5058614d8729a131"
WEIGHTS="
dinov3.gguf                     0dd4ffd4b46a248f5b7d49c35275d68461fbf73f57ddb4c1fa8afb4f7bb45a0d
pixal3d_naf.gguf                c4f6cd80e94c8d120360ba50a3633322e6ecce0163966e3b7650b24f99c18569
pixal3d_ss_flow_sv.gguf         75eeb538c5485e02f091d1fc8a55c8132035076a4e01b7e9607883deff3852c4
ss_dec.gguf                     2790b5eecb261cc877d9bf175ce2bd6dd48cd65be8c042c5f5bc023dfca01cf7
pixal3d_shape_flow_512_sv.gguf  13f5df430ca49e6011827a3eeb208f047bdbad1fd4e52549809eaab63b83e19e
shape_dec.gguf                  0de7c7a675022dd8696d526a9279e5a50b2a35c8a79452f434a72dc53d40f169
pixal3d_shape_flow_1024_sv.gguf 7cb1ecb189719edbbb991d16271ad0f8ab8bf54154df7795830aadba27f0efae
pixal3d_tex_flow_1024_sv.gguf   06ef23d3badafc6f8ffcecebbc2bd0297461852b6c125dc4448f80d78040ee17
tex_dec.gguf                    88b4fced46455e02f316664d5c43584a311921dd9a1cdc1b7b7d981cca9214d4
pixal3d-models.json             e127c0f70e6dc43c07b4c1afc896a7e14353e5c2e7aa6ce0fd82406a6a94c61e
LICENSE.md                      95774b0e9d74792a64ddbbd4c51388ea0df1c1a77f8fff0ebce7cb812822dbad
MIT_LICENSE.md                  8a37ac9d3587a7cec9bd64fe9043482de7ad53a461532faa3a9f4840cf3f7e59
DINOV3_LICENSE.md               25d122eb8f5b880fd23c736fb6ea8018ee45c12237e00b8a86d14c653904999e
README.md                       d9cda1603b2828844623817d892ac20ee30c775c519798d8f60329fbd49ca4cf
"

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/engine"
MODELS="$ENGINE/models/pixal3d-sv"
# Where installs before the Swift engine kept it: inside a clone of image-to-3dlab.
OLD_LAB="$HERE/image-to-3dlab"
OLD_ENGINE="$OLD_LAB/vendor/pixal3d-cpp"
YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
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
# every double-click of Install Mimic.command ask again. They are this folder's own files.
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
# brew itself on the PATH for the rest of this script.
eval "$(/opt/homebrew/bin/brew shellenv)"
ok "Homebrew"

# --- Apps --------------------------------------------------------------------------------------
step "Apps"
[ -d /Applications/Blender.app ] || brew install --cask blender
[ -d "/Applications/Draw Things.app" ] || brew install --cask draw-things
ok "Blender, Draw Things"

# --- The 3D engine ---------------------------------------------------------------------------
step "Mimic's 3D engine"
mkdir -p "$MODELS"
# An older install has the engine and 8.4 GB of models inside image-to-3dlab: move them rather
# than download them again. Its trellis-cli is kept only if it's the build this Mimic pins.
if [ -d "$OLD_ENGINE" ]; then
  if [ ! -x "$ENGINE/trellis-cli" ] && grep -q "^$PIXAL3D_VERSION " "$OLD_ENGINE/build/VERSION" 2>/dev/null; then
    mv "$OLD_ENGINE/build/trellis-cli" "$OLD_ENGINE"/build/libggml*.dylib "$OLD_ENGINE"/build/LICENSE-* \
       "$OLD_ENGINE/build/VERSION" "$ENGINE/"
  fi
  echo "$WEIGHTS" | while read -r name sum; do
    if [ -n "$name" ] && [ ! -e "$MODELS/$name" ] && [ -f "$OLD_ENGINE/models/pixal3d-sv/$name" ]; then
      mv "$OLD_ENGINE/models/pixal3d-sv/$name" "$MODELS/"
    fi
  done
  # What's left is the old helper tools (a git clone and a Python setup), no longer used.
  rm -rf "$OLD_LAB"
  ok "Moved the 3D engine out of image-to-3dlab"
fi

if [ ! -x "$ENGINE/trellis-cli" ]; then
  tarball="$TMPDIR/pixal3d-metal.tar.gz"
  curl -fL --progress-bar -o "$tarball" "$PIXAL3D_URL"
  echo "$PIXAL3D_SHA256  $tarball" | shasum -a 256 -c - >/dev/null \
    || die "The 3D engine download is damaged. Run the installer again."
  tar -xzf "$tarball" -C "$ENGINE" --strip-components=1
fi
"$ENGINE/trellis-cli" --help >/dev/null 2>&1 || die "The 3D engine doesn't start on this Mac."
ok "Pixal3D"

# Each file is checked, so a re-run skips what's already right and a broken download resumes
# (it goes to .part first, so a half file is never taken for a whole one).
fetch() {
  local file="$MODELS/$1" sum="$2"
  good() { echo "$sum  $1" | shasum -a 256 -c - >/dev/null 2>&1; }
  [ -f "$file" ] && good "$file" && return 0
  rm -f "$file"
  if ! { [ -f "$file.part" ] && good "$file.part"; }; then
    echo "  ⏳ $1"
    # 22 is an HTTP error, such as resuming a .part that's already full length but wrong:
    # that one is thrown away, so the next run starts it afresh.
    curl -fL --progress-bar -C - -o "$file.part" "$WEIGHTS_URL/$1" \
      || { [ $? = 22 ] && rm -f "$file.part"; die "Downloading $1 stopped. Run the installer again: it carries on where it stopped."; }
    good "$file.part" || { rm -f "$file.part"; die "$1 downloaded damaged. Run the installer again."; }
  fi
  mv "$file.part" "$file"
}
echo "  Checking the 3D model files (8.4 GB). Downloading them, if needed, is the long part."
echo "$WEIGHTS" | while read -r name sum; do [ -z "$name" ] || fetch "$name" "$sum"; done
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

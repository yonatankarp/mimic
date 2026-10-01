#!/usr/bin/env bash
# Maintainer tool: build pixal3d.cpp for Metal and package it as the relocatable tarball that
# app downloads on first launch (app/Sources/MimicCore/EngineDownload.swift), so users never need Xcode.
# The engine workflow (.github/workflows/engine.yml) runs it; it also runs on a Mac with Xcode,
# cmake and ninja.
#
#   tools/package_pixal3d.sh <pixal3d.cpp checkout> <build dir> <out dir>
#
# The checkout must be clean, at the commit to build, with its submodules checked out:
#   git clone https://github.com/raven38/pixal3d.cpp <checkout>
#   git -C <checkout> checkout <commit> && git -C <checkout> submodule update --init
# The script applies tools/pixal3d-steps.patch itself (Mimic stops any run whose engine
# ignores PIXAL3D_STEPS), then builds trellis-cli into <build dir>, which must be outside the
# checkout and is wiped first.
#
# Two builds of the same commit with the same Xcode give the same tarball, byte for byte:
# - it targets macOS 14, the oldest Mimic supports, or the tarball only runs on yours;
# - source and build paths are mapped away, or every assert message carries them;
# - SOURCE_DATE_EPOCH is the commit's time, which the build stamps in place of the clock;
# - ggml is built without -mcpu=native, so the binary doesn't depend on the build Mac's chip;
# - the tar has sorted entries, fixed owners, modes and times, no macOS metadata, and gzip
#   leaves out its own timestamp.
#
# The build finds its libraries through an absolute rpath into the build tree (plus a
# Linux-style $ORIGIN that macOS ignores), so a moved copy dies at launch. Every rpath is
# replaced with @loader_path, and everything is re-signed ad hoc because the edit voids the
# signature.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
patch="$here/pixal3d-steps.patch"
src="$(cd "$1" && pwd -P)"
mkdir -p "$2" "$3"
build="$(cd "$2" && pwd -P)"; out="$(cd "$3" && pwd -P)"
case "$build/" in "$src"/*) echo "refusing: the build dir is inside the checkout" >&2; exit 1 ;; esac

if [ -n "$(git -C "$src" status --porcelain)" ] || git -C "$src" submodule status | grep -q '^[-+U]'; then
  echo "refusing: $src isn't a clean checkout with its submodules at their commits" >&2; exit 1
fi
git -C "$src" apply --check "$patch"
git -C "$src" apply "$patch"

commit="$(git -C "$src" rev-parse --short=7 HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$src" log -1 --format=%ct HEAD)"
export SOURCE_DATE_EPOCH

rm -rf "$build"; mkdir -p "$build"
M="-ffile-prefix-map=$src=pixal3d.cpp -ffile-prefix-map=$build=build"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DGGML_NATIVE=OFF \
  "-DCMAKE_C_FLAGS=$M" "-DCMAKE_CXX_FLAGS=$M" "-DCMAKE_OBJC_FLAGS=$M" "-DCMAKE_OBJCXX_FLAGS=$M"
cmake --build "$build" --target trellis-cli

minos="$(otool -l "$build/trellis-cli" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
name="pixal3d-metal-$commit-macos$minos"
stage="$(mktemp -d)/$name"
mkdir -p "$stage"

cp "$build/trellis-cli" "$stage/"
cp -P "$build"/libggml*.dylib "$stage/"
for f in "$stage/trellis-cli" "$stage"/libggml*.*.*.dylib; do
  while read -r rp; do install_name_tool -delete_rpath "$rp" "$f"; done \
    < <(otool -l "$f" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')
  install_name_tool -add_rpath @loader_path "$f"
  codesign -s - -f "$f" 2>/dev/null
done
for p in "$HOME" "$src" "$build"; do
  if grep -rlF "$p" "$stage" >/dev/null 2>&1; then
    echo "refusing: $p still appears in the artefact" >&2; exit 1
  fi
done

cp "$src/LICENSE" "$stage/LICENSE-pixal3d.cpp" 2>/dev/null || cp "$src/LICENSE.md" "$stage/LICENSE-pixal3d.cpp"
cp "$src/thirdparty/ggml/LICENSE" "$stage/LICENSE-ggml"
cp "$here/LICENSE-image-to-3dlab" "$stage/LICENSE-image-to-3dlab"
# The first line is what EngineDownload.version checks; the rest says how it was made.
{
  printf 'pixal3d.cpp %s (%s), Metal, macOS >= %s\n' "$commit" "$(git -C "$src" rev-parse HEAD)" "$minos"
  printf 'patch: pixal3d-steps.patch sha256 %s\n' "$(shasum -a 256 "$patch" | cut -d' ' -f1)"
  printf 'toolchain: %s, macOS SDK %s, %s, %s\n' "$(xcodebuild -version | paste -sd' ' -)" \
    "$(xcrun --show-sdk-version)" "$(clang --version | head -1)" "$(cmake --version | head -1)"
} > "$stage/VERSION"
"$stage/trellis-cli" --help >/dev/null 2>&1 || { echo "packaged trellis-cli does not start" >&2; exit 1; }

# Only what's in the files goes in the tar: no owner, umask, clock or Finder metadata.
when="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
chmod 755 "$stage" "$stage/trellis-cli" "$stage"/libggml*.*.*.dylib
chmod 644 "$stage/VERSION" "$stage"/LICENSE-*
find "$stage" -type l -exec chmod -h 755 {} +
find "$stage" -exec touch -h -d "$when" {} +
(cd "$(dirname "$stage")" && find "$name" | LC_ALL=C sort |
  COPYFILE_DISABLE=1 tar -c -n -T - -f - --format ustar --uid 0 --gid 0 --uname '' --gname '' \
    --no-mac-metadata --no-xattrs --no-acls --no-fflags) | gzip -n -9 > "$out/$name.tar.gz"
(cd "$out" && shasum -a 256 "$name.tar.gz" | tee "$name.tar.gz.sha256")

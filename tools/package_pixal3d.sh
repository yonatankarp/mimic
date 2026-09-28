#!/usr/bin/env bash
# Maintainer tool: package a pixal3d.cpp Metal build as the relocatable tarball that
# setup.sh downloads, so users never need Xcode.
#
#   tools/package_pixal3d.sh <pixal3d.cpp checkout> <build dir> <out dir>
#
# Build it for the oldest macOS we support, or the tarball only runs on yours, and map
# the source path away, or every assert message carries the maintainer's home directory:
#   S=<checkout>; M="-ffile-prefix-map=$S=pixal3d.cpp"
#   cmake -S "$S" -B <build> -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
#     "-DCMAKE_C_FLAGS=$M" "-DCMAKE_CXX_FLAGS=$M" "-DCMAKE_OBJC_FLAGS=$M" "-DCMAKE_OBJCXX_FLAGS=$M"
#   cmake --build <build> --target trellis-cli
#
# The build finds its libraries through an absolute rpath into the build tree (plus a
# Linux-style $ORIGIN that macOS ignores), so a moved copy dies at launch. Every rpath is
# replaced with @loader_path, which is also what keeps the maintainer's path out of the
# artefact, and everything is re-signed ad hoc because the edit voids the signature.
set -euo pipefail

src="$1"; build="$2"; out="$3"
commit="$(git -C "$src" rev-parse --short HEAD)"
minos="$(otool -l "$build/trellis-cli" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
name="pixal3d-metal-$commit-macos$minos"
stage="$(mktemp -d)/$name"
mkdir -p "$stage" "$out"

cp "$build/trellis-cli" "$stage/"
cp -P "$build"/libggml*.dylib "$stage/"
for f in "$stage/trellis-cli" "$stage"/libggml*.*.*.dylib; do
  while read -r rp; do install_name_tool -delete_rpath "$rp" "$f"; done \
    < <(otool -l "$f" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')
  install_name_tool -add_rpath @loader_path "$f"
  codesign -s - -f "$f" 2>/dev/null
done
if grep -rl "$HOME" "$stage" >/dev/null 2>&1; then
  echo "refusing: $HOME still appears in the artefact" >&2; exit 1
fi

cp "$src/LICENSE" "$stage/LICENSE-pixal3d.cpp" 2>/dev/null || cp "$src/LICENSE.md" "$stage/LICENSE-pixal3d.cpp"
cp "$src/thirdparty/ggml/LICENSE" "$stage/LICENSE-ggml"
printf 'pixal3d.cpp %s (%s), Metal, macOS >= %s\n' "$commit" "$(git -C "$src" rev-parse HEAD)" "$minos" > "$stage/VERSION"
"$stage/trellis-cli" --help >/dev/null 2>&1 || { echo "packaged trellis-cli does not start" >&2; exit 1; }

tar -C "$(dirname "$stage")" -czf "$out/$name.tar.gz" "$name"
shasum -a 256 "$out/$name.tar.gz"

#!/usr/bin/env bash
# Maintainer tool: build Mimic.app and put it in a disk image, the way most Mac apps arrive:
# open the image, drag Mimic onto Applications.
#
#   tools/package_dmg.sh <out dir>
set -euo pipefail
out="$1"
here="$(cd "$(dirname "$0")/.." && pwd)"
version="$(git -C "$here" rev-parse --short HEAD)"
app="$here/app/$("$here/app/bundle.sh" release)"
stage="$(mktemp -d)/Mimic"
mkdir -p "$stage" "$out"
ditto "$app" "$stage/Mimic.app"
ln -s /Applications "$stage/Applications"
dmg="$out/Mimic-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname Mimic -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
echo "$dmg"
shasum -a 256 "$dmg"

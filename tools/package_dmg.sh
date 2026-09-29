#!/usr/bin/env bash
# Maintainer tool: build Mimic.app and put it in a disk image, the way most Mac apps arrive:
# open the image, drag Mimic onto Applications.
#
#   tools/package_dmg.sh <out dir>
set -euo pipefail
out="$1"
here="$(cd "$(dirname "$0")/.." && pwd)"
version="${MIMIC_VERSION:-$(git -C "$here" rev-parse --short HEAD)}"
app="$here/app/$("$here/app/bundle.sh" release)"
stage="$(mktemp -d)/Mimic"
mkdir -p "$stage" "$out"
ditto "$app" "$stage/Mimic.app"
ln -s /Applications "$stage/Applications"
# Mimic is signed by its makers rather than by Apple, so the first open needs one extra step.
cat > "$stage/If Mimic won't open.txt" <<'TEXT'
The first time you open Mimic, your Mac may say it can't check it ("Apple could not verify
Mimic"). That's because Mimic is a free app that isn't registered with Apple. To open it:

1. Press Done on that message.
2. Open System Settings, then Privacy & Security.
3. Scroll down to "Mimic was blocked" and press Open Anyway.
4. Confirm with your Mac password or Touch ID.

You only need to do this once.
TEXT
dmg="$out/Mimic-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname Mimic -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
echo "$dmg"
shasum -a 256 "$dmg"

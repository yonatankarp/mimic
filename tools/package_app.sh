#!/usr/bin/env bash
# Maintainer tool: build Mimic.app and zip it as the file setup.sh downloads, so nobody needs
# Xcode or Swift to install Mimic.
#
#   tools/package_app.sh <out dir>
#
# Prints the zip's sha256: that and the release URL go into setup.sh's MIMIC_APP_URL and
# MIMIC_APP_SHA256. The app is signed ad hoc only; it opens without a Gatekeeper warning because
# setup.sh downloads it with curl, which doesn't mark files as downloaded from the internet.
set -euo pipefail
out="$1"
here="$(cd "$(dirname "$0")/.." && pwd)"
version="$(git -C "$here" rev-parse --short HEAD)"
app="$("$here/app/bundle.sh" release)"
mkdir -p "$out"
zip="$out/Mimic-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$here/app/$app" "$zip"
echo "$zip"
shasum -a 256 "$zip"

#!/usr/bin/env bash
# Assembles the app from `swift build`: a Swift package builds a bare binary, and a Mac app is
# that binary inside a folder with an Info.plist and an icon.
#
#   ./bundle.sh          # "Mimic Dev.app" in app/build/, id com.mimic.app.dev
#   ./bundle.sh release  # "Mimic.app", id com.mimic.app: what the disk image ships
#
# The dev build has its own name and id so it never replaces or reuses the settings of the
# Mimic you actually use.
set -euo pipefail
cd "$(dirname "$0")"
kind="${1:-dev}"
if [ "$kind" = release ]; then name="Mimic"; id="com.mimic.app"; else name="Mimic Dev"; id="com.mimic.app.dev"; fi

# Record the SDK it was really built with: SwiftPM records the deployment target (15.0) as the
# SDK, and macOS gives an app built "for 15" the old look instead of Liquid Glass.
sdk="$(xcrun --show-sdk-version)"
swift build -c release --product mimic -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$sdk" >/dev/null
bin="$(swift build -c release --show-bin-path)/mimic"
app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/mimic"
cp Mimic.icns "$app/Contents/Resources/Mimic.icns"
# SwiftPM's resource bundle (the tour's sample picture); Bundle.main.resourceURL is where the app looks.
cp -R "$(dirname "$bin")/Mimic_Mimic.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>mimic</string>
  <key>CFBundleIconFile</key><string>Mimic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MIMIC_VERSION:-0.1}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$app" 2>/dev/null
# The dev build uses this checkout as its Mimic folder (runs/ and engine/). The release build
# finds its own: ~/Documents/Mimic and ~/Library/Application Support/Mimic.
[ "$kind" = release ] || defaults write "$id" installDir "$(cd .. && pwd)"
echo "$app"

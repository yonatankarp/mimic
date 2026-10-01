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

# Record the SDK it was really built with: SwiftPM records the deployment target (26.0) as the
# SDK, and macOS gives an app the look of the SDK it says it was built with.
sdk="$(xcrun --show-sdk-version)"
# What this build is, shown in About, Settings and `mimic --version`: a release's version comes
# from its tag (MIMIC_VERSION); anything else says where it stands, e.g. 0.4.0-3-g941a66c.
version="${MIMIC_VERSION:-$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"
build="$(git rev-list --count HEAD 2>/dev/null || echo 0)"  # grows with every commit
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
swift build -c release --product mimic -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$sdk" >/dev/null
bin="$(swift build -c release --show-bin-path)/mimic"
app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/mimic"
# Sparkle, for updates (the binary looks in ../Frameworks). ditto keeps its symlinks. Its XPC
# services are only for sandboxed apps, and Mimic isn't one.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$(dirname "$bin")/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/XPCServices" "$sparkle/Versions/B/XPCServices"
cp Mimic.icns "$app/Contents/Resources/Mimic.icns"
# The licences that must travel with copies: Mimic's, and Sparkle's (with the notices of the code
# it includes) from the version swift build resolved.
{
  printf 'Mimic\n=====\n\n'; cat ../LICENSE
  printf '\n\nSparkle\n=======\n\n'; cat .build/checkouts/Sparkle/LICENSE
} > "$app/Contents/Resources/Acknowledgements.txt"
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
  <key>CFBundleShortVersionString</key><string>${version:-dev}</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>MimicCommit</key><string>$commit</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>SUFeedURL</key><string>https://github.com/yonatankarp/mimic/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>Dw9fswgPGLG2UoKzVMTIdvoQZd/m317sFxOecEoDXMk=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Yonatan Karp-Rudin</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Releases are signed with Mimic's own certificate (MIMIC_SIGN_IDENTITY, set up by CI): the same
# signer every version, so macOS knows an update is the same app and doesn't ask again for saved
# AI keys. Anything else is signed ad hoc, which is enough to run on this Mac. Inside out:
# Sparkle's helpers, then Sparkle, then the app.
sign() {
  if [ -n "${MIMIC_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp=none -s "$MIMIC_SIGN_IDENTITY" ${MIMIC_SIGN_KEYCHAIN:+--keychain "$MIMIC_SIGN_KEYCHAIN"} "$1"
  else
    codesign --force -s - "$1" 2>/dev/null
  fi
}
for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$app"; do sign "$code"; done
# The dev build uses this checkout as its Mimic folder (runs/ and engine/). The release build
# finds its own: ~/Documents/Mimic and ~/Library/Application Support/Mimic.
[ "$kind" = release ] || defaults write "$id" installDir "$(cd .. && pwd)"
echo "$app"

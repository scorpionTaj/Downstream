#!/bin/zsh
# Builds build/Downstream.app with the Command Line Tools only.
#
# Usage: scripts/bundle.sh [debug|release]   (default: release)
#   UNIVERSAL=1            build for Apple Silicon and Intel
#   BUNDLE_ID=...          build a side-by-side test copy with its own app ID (own settings, windows and
#                          Dock icon), e.g. com.scorpiontaj.downstream.dev; it still installs real releases
#   SIGN_IDENTITY="..."    sign with this identity (e.g. "Developer ID Application: Name (TEAMID)");
#                          without it the app is signed ad hoc, which only runs on this Mac without a warning.
set -euo pipefail

config="${1:-release}"
root="${0:A:h:h}"
app="$root/build/Downstream.app"

cd "$root"
arch_args=()
[[ "${UNIVERSAL:-0}" == 1 ]] && arch_args=(--arch arm64 --arch x86_64)
swift build -c "$config" --product Downstream "${arch_args[@]}"
bin="$(swift build -c "$config" --show-bin-path "${arch_args[@]}")/Downstream"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Downstream"
cp Support/Info.plist "$app/Contents/Info.plist"
if [[ -n "${BUNDLE_ID:-}" ]]; then
  release_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Add :DownstreamReleaseBundleID string $release_id" "$app/Contents/Info.plist"
fi
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R Support/*.lproj "$app/Contents/Resources/"
cp CHANGELOG.md "$app/Contents/Resources/CHANGELOG.md"
plutil -lint -s "$app/Contents/Info.plist"

# Hardened runtime is required for notarization. Downstream needs no entitlements:
# it isn't sandboxed and only starts other programs (yt-dlp, ffmpeg, aria2c, brew).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --options runtime --sign - "$app"
fi
codesign --verify --strict "$app"
echo "Built $app ($(lipo -archs "$app/Contents/MacOS/Downstream"))"

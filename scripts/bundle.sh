#!/bin/zsh
# Builds build/Downstream.app with the Command Line Tools only.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

config="${1:-release}"
root="${0:A:h:h}"
app="$root/build/Downstream.app"

cd "$root"
swift build -c "$config" --product Downstream
bin="$(swift build -c "$config" --show-bin-path)/Downstream"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Downstream"
cp Support/Info.plist "$app/Contents/Info.plist"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$app/Contents/Resources/"
plutil -lint -s "$app/Contents/Info.plist"

# Ad-hoc signature so Gatekeeper and TCC treat it as one stable app locally.
# Release builds will re-sign with a Developer ID and the hardened runtime.
codesign --force --sign - --timestamp=none "$app"
echo "Built $app"

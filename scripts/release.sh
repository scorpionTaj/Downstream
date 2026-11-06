#!/bin/zsh
# Builds a universal, signed Downstream and packages it as build/Downstream-<version>.dmg.
#
# Without an Apple Developer ID the app is signed ad hoc: it works, but people have to
# right-click › Open (or allow it in System Settings › Privacy & Security) the first time.
#
# With a Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=downstream \
#   scripts/release.sh
# where the profile was saved once with:
#   xcrun notarytool store-credentials downstream --apple-id you@example.com --team-id TEAMID
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
dmg="$root/build/Downstream-$version.dmg"

UNIVERSAL=1 "$root/scripts/bundle.sh" release

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R build/Downstream.app "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Downstream $version" -srcfolder "$staging" -fs HFS+ -format UDZO -quiet "$dmg"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
  else
    echo "Signed but not notarized: set NOTARY_PROFILE to notarize."
  fi
else
  echo "Signed ad hoc (no SIGN_IDENTITY): first launch needs right-click › Open."
fi

shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "Done: $dmg"

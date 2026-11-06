# Developing Downstream

## Building and testing

Only the Xcode Command Line Tools are needed. They ship without the macro plugins for SwiftUI's `@State`, SwiftData's `@Model`, Swift Testing and `#Preview`, and without XCTest, so the code:

- keeps view state in `@Observable` models (passed with `.environment`) or `@StateObject`, never `@State`
- stores history, presets and unfinished downloads as JSON files instead of SwiftData
- tests with `DownstreamChecks`, a plain executable that exits non-zero on failure

**GitHub Actions does all the building and testing** (`.github/workflows/ci.yml`): every push and pull request runs the offline checks and a strict universal build, pushes to `main` and a weekly schedule also run the live download suite, and the app is uploaded as an artifact. Releases (`.github/workflows/release.yml`) run the checks and build the DMG. Watch a run with `gh run watch` or the Actions tab — there is nothing you have to build or run locally.

The commands exist for when you're iterating and want quick feedback without waiting for CI:

```bash
swift run DownstreamChecks          # offline checks
swift run DownstreamChecks --live   # also real downloads and a real update from GitHub (needs the network, yt-dlp, ffmpeg)
./scripts/bundle.sh                 # build/Downstream.app for this Mac
UNIVERSAL=1 ./scripts/bundle.sh     # Apple Silicon and Intel
```

### A test copy next to your installed Downstream

```bash
BUNDLE_ID=com.scorpiontaj.downstream.dev ./scripts/bundle.sh
```

It has its own app ID, so its settings, windows and Dock icon are separate from the Downstream you use. Handy launch arguments (also for any build):

```bash
open build/Downstream.app --args \
  -downloadFolder /tmp/dl -DownstreamDataDirectory /tmp/data \
  -acceptedNotice YES -checkForAppUpdates NO -autoUpdateYtDlp NO -AppleLanguages "(fr)"
```

Test copies can also read updates from a local feed instead of GitHub (`-DownstreamUpdateFeedURL http://127.0.0.1:8765/latest.json`, a JSON file shaped like GitHub's latest-release response).

## Releasing

1. Add a section for the new version at the top of [CHANGELOG.md](../CHANGELOG.md) and set `CFBundleShortVersionString` in `Support/Info.plist` to match (a check fails if they differ).
2. Commit, then tag and push: `git tag v1.3.0 && git push origin main v1.3.0`.

The **Release** workflow runs the checks, builds the universal app and the designed DMG (`dmgbuild` with `Support/dmg/settings.py`), and publishes a GitHub release using that CHANGELOG section as notes. Installed copies find it on their next daily check.

Without an Apple Developer ID the app is signed ad hoc. With one, set `SIGN_IDENTITY` and `NOTARY_PROFILE` (see `scripts/release.sh`).

## Generated assets

- `scripts/make-icon.swift` → `Support/AppIcon.icns`
- `scripts/make-dmg-background.swift` → `Support/dmg/background.tiff`
- `scripts/translations.py` → `Support/{fr,ar}.lproj/Localizable.strings` (keys are the English text in the code)

## Layout

- `Sources/DownstreamCore`: the yt-dlp engine, downloads, persistence, updates and changelog. No UI code.
- `Sources/Downstream`: the SwiftUI app.
- `Sources/DownstreamChecks`: the checks.
- `scripts/`, `Support/`: build, sign, package and generated assets.
- `.github/workflows/`: CI and releases.

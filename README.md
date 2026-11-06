# Downstream

A native macOS app for downloading video and audio, built on [yt-dlp](https://github.com/yt-dlp/yt-dlp).
It is a from-scratch implementation inspired by the feature set of Parabolic and Macabolic and contains no code from either project.

- macOS 15 Sequoia or later
- MIT license

## Install

1. Open `Downstream-<version>.dmg` and drag Downstream to Applications.
2. The first time, right-click Downstream › Open (or allow it in System Settings › Privacy & Security).
   Builds aren't notarized yet, so macOS asks once.
3. Install the tools it uses (below). Downstream shows the exact command if any are missing.

## Requirements

Downstream runs the Homebrew copies of its tools:

```bash
brew install yt-dlp ffmpeg aria2
```

`yt-dlp` and `ffmpeg` are required. `aria2` is optional and enables multi-connection downloads.
The app looks in `/opt/homebrew/bin` (Apple Silicon) and `/usr/local/bin` (Intel).

## Building

Only the Xcode Command Line Tools are needed (`xcode-select --install`). Xcode itself is not required.

```bash
swift run DownstreamChecks          # run the offline checks
swift run DownstreamChecks --live   # also run real downloads (needs the network)
./scripts/bundle.sh             # build build/Downstream.app
open build/Downstream.app
```

The Command Line Tools ship without the macro plugins for SwiftUI's `@State`, SwiftData's `@Model`, Swift Testing and `#Preview`, and without XCTest. So the code:

- keeps view state in `@Observable` models (passed with `.environment`) or `@StateObject`, never `@State`
- stores history and presets as JSON files instead of SwiftData
- tests with `DownstreamChecks`, a plain executable that exits non-zero on failure

## Releasing

```bash
scripts/release.sh                  # universal app + build/Downstream-<version>.dmg (+ .sha256)
```

The version comes from `Support/Info.plist`. Without a Developer ID the app is signed ad hoc.
With one, set `SIGN_IDENTITY` (and `NOTARY_PROFILE` to notarize and staple); see the comments in `scripts/release.sh`.
The icon is drawn by `scripts/make-icon.swift`, which writes `Support/AppIcon.icns`.

## Layout

- `Sources/DownstreamCore`: the yt-dlp engine and tool discovery. No UI code.
- `Sources/Downstream`: the SwiftUI app.
- `Sources/DownstreamChecks`: the checks for `DownstreamCore`.
- `scripts/bundle.sh`, `scripts/release.sh`, `Support/`: build, sign and package the app.

## Legal

Downstream is a neutral tool. Download only content you have the right to download.

<p align="center"><img src="Support/AppIcon-1024.png" width="128" alt="Downstream icon"></p>

<h1 align="center">Downstream</h1>

<p align="center">
A native macOS app for downloading video and audio, built on <a href="https://github.com/yt-dlp/yt-dlp">yt-dlp</a>.<br>
<a href="https://github.com/scorpionTaj/Downstream/actions/workflows/ci.yml"><img src="https://github.com/scorpionTaj/Downstream/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/scorpionTaj/Downstream/releases/latest"><img src="https://img.shields.io/github/v/release/scorpionTaj/Downstream" alt="Latest release"></a>
</p>

Downstream is a from-scratch implementation inspired by the feature set of Parabolic and Macabolic; it contains no code from either project.

- macOS 15 Sequoia or later, Apple Silicon and Intel
- English, French and Arabic (right-to-left), picked from your system language
- MIT license

## Features

- **Downloads** from YouTube, Vimeo and every other site yt-dlp supports: video up to 4K (MP4, WebM, MKV) or audio only (MP3, M4A, Opus, FLAC, WAV)
- **Queue** with a limit on simultaneous downloads, pause and resume from the partial file, retry, and cancel that cleans up after itself
- **Playlists** with a picker for the videos you want
- **Subtitles, thumbnail, metadata and chapters** embedded in the file
- **SponsorBlock** to cut or mark sponsor segments, **cookies** from your browser or a cookies.txt, **aria2** for faster transfers, speed limits, file name templates and extra yt-dlp arguments
- **Presets**, and defaults for new downloads in Settings
- **History** of completed and failed downloads, with download again
- **Menu bar** popover to watch and control downloads, and download a copied link in one click
- **Updates**: yt-dlp is kept up to date weekly through Homebrew, and Downstream updates itself from GitHub Releases with a progress bar
- Unfinished downloads survive quitting and come back paused

## Install

1. Download `Downstream-<version>.dmg` from [Releases](https://github.com/scorpionTaj/Downstream/releases/latest), open it and drag Downstream into Applications.
2. The first time, right-click Downstream › Open (or allow it in System Settings › Privacy & Security). Builds aren't notarized yet, so macOS asks once.
3. Install the tools it uses. Downstream shows the exact command if any are missing:

```bash
brew install yt-dlp ffmpeg aria2
```

`yt-dlp` and `ffmpeg` are required. `aria2` is optional and enables multi-connection downloads.
Downstream looks in `/opt/homebrew/bin` (Apple Silicon) and `/usr/local/bin` (Intel), or a path you set in Settings › Tools.

## Building

Only the Xcode Command Line Tools are needed (`xcode-select --install`). Xcode itself is not required.

```bash
swift run DownstreamChecks          # the offline checks
swift run DownstreamChecks --live   # also real downloads (needs the network, yt-dlp and ffmpeg)
./scripts/bundle.sh                 # build build/Downstream.app
open build/Downstream.app
```

The Command Line Tools ship without the macro plugins for SwiftUI's `@State`, SwiftData's `@Model`, Swift Testing and `#Preview`, and without XCTest. So the code:

- keeps view state in `@Observable` models (passed with `.environment`) or `@StateObject`, never `@State`
- stores history and presets as JSON files instead of SwiftData
- tests with `DownstreamChecks`, a plain executable that exits non-zero on failure

## Releasing

Releases are built on GitHub, not locally:

```bash
git tag v1.2.0 && git push origin v1.2.0
```

The **Release** workflow sets the version from the tag, runs the checks, builds a universal app and the designed DMG (`dmgbuild` with `Support/dmg/settings.py`), and publishes a GitHub release with the DMG and its SHA-256. Installed copies of Downstream find it on their next daily check. **CI** runs the checks and a build on every push and pull request.

To build a DMG locally anyway: `pip install dmgbuild && scripts/release.sh`. Without a Developer ID the app is signed ad hoc; with one, set `SIGN_IDENTITY` and `NOTARY_PROFILE` (see `scripts/release.sh`).

Generated assets: `scripts/make-icon.swift` (app icon), `scripts/make-dmg-background.swift` (DMG window), `scripts/translations.py` (French and Arabic strings in `Support/*.lproj`).

## Layout

- `Sources/DownstreamCore`: the yt-dlp engine, downloads, persistence and updates. No UI code.
- `Sources/Downstream`: the SwiftUI app.
- `Sources/DownstreamChecks`: the checks.
- `scripts/`, `Support/`: build, sign, package and generated assets.
- `.github/workflows/`: CI and releases.

## Legal

Downstream is a neutral tool. Download only content you have the right to download.

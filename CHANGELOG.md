# Changelog

All notable changes to Downstream. The newest version is first. Downstream shows this list in Settings › About and after an update.

## [1.2.3] - 2026-11-06

### Improved
- The working bar — starting a download, converting, embedding, installing an update — is clearer: the whole bar is more strongly tinted and the moving shine is brighter, so it can't be mistaken for a partial bar. The shine still sweeps the full width from edge to edge.

## [1.2.2] - 2026-11-06

### Fixed
- Failed downloads are now kept in History, so the Failed filter and "Try again" work; they used to vanish when the app quit.
- Editing the link while the Add Download sheet was still fetching could start a download with the previous video's details. The stale fetch is now cancelled.
- Quitting while a download runs now waits (up to a few seconds) for yt-dlp to stop, so nothing keeps running after the app is gone and resuming can't collide with a leftover process.
- A video link that carries a `&list=` parameter downloads just that video again, not the whole playlist.
- Adding the same link into the same folder twice is refused — two downloads would write the same files. The sheet says the link is already downloading.
- "Update yt-dlp Now" waits for running downloads to finish instead of replacing yt-dlp underneath them.
- Cancelling an aria2 download now removes its partial files and control file (nothing was cleaned up before, since aria2 reports no file names).
- Cancelling a download only deletes yt-dlp's own partial files now; your own files sharing the video's name (`.nfo`, `.txt`, `.json`…) are left alone.
- An update whose release ships no checksum is refused instead of installed with only a signature check.
- A failed update says so when the old version had to be left in the Trash.
- A version heading like `1.2.2-beta` no longer breaks the "What's New" parser.
- History survives a corrupted file: two unsalvageable saves in the same second no longer destroy each other's backup.
- Relaunching after an update can no longer hang on a stalled quit, and says so when it can't relaunch.

### Improved
- Tool checks (yt-dlp, ffmpeg, aria2) run in parallel, so "Check again" is up to three times faster.
- A tool path that points to a folder is rejected instead of failing confusingly later.
- A GitHub rate limit or other HTTP error now says what happened instead of a generic network error.
- One damaged format in a video's metadata no longer hides the rest of the quality list.
- The build is warning-free and CI fails on any new warning.

## [1.2.1] - 2026-11-06

### Fixed
- Steps without a percentage (starting, converting, embedding, installing an update) now fill the whole bar with a moving shine. The old short sliding stripe looked like the bar was stuck at 25%.

## [1.2.0] - 2026-11-06

### Added
- Welcome guide the first time you open Downstream (Help › Welcome Guide shows it again).
- Choose what ⌘Q does: quit, or keep Downstream running in the menu bar to finish your downloads. "Remember my choice" saves it, and Settings › General changes it.
- Reorganized Settings: General, Downloads, Advanced and About, in the sunset design.
- Appearance (system, light or dark) and language (English, French, Arabic) in Settings › General.
- Changelog in Settings › About, and "What's New" after an update.

### Fixed
- The update progress bar now reaches the end; it could stop part-way.
- "Relaunch now" after an update now quits and reopens Downstream (it did nothing while the update window was open).

## [1.1.1] - 2026-11-06

### Fixed
- Updating from the published disk image failed its signature check.

## [1.1.0] - 2026-11-06

### Added
- Sunset redesign: colored sidebar, download cards with state chips and gradient progress, roomier screens, new icon.
- In-app updates from GitHub Releases, with a progress bar and checksum and signature checks.
- yt-dlp updates itself weekly through Homebrew.
- Failed downloads stay in History, with All, Completed and Failed tabs.
- Downloads menu, Paste Link and Download (⇧⌘V), Open Downloads Folder (⇧⌘O), ⌘1–⌘6 for each section, Help links.
- Menu bar popover: control each download, pause or resume all, recent downloads, update banner.
- French and Arabic, with right-to-left layout in Arabic.
- Designed installer disk image.

## [1.0.0] - 2026-11-06

### Added
- First release: queue with pause, resume and retry; history; presets; playlists; subtitles, SponsorBlock, cookies and aria2; menu bar mode; unfinished downloads restored after quitting.

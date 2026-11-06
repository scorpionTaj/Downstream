# Changelog

All notable changes to Downstream. The newest version is first. Downstream shows this list in Settings › About and after an update.

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

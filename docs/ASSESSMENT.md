# Downstream — Project Assessment

*Written 2026-11-06 after a full audit of all 43 Swift files, a complete test run (offline + live checks, release bundle, GUI smoke test), and a bug-fix pass. Reflects the state of the code after that pass; see the git history for the fixes.*

## What Downstream is

A native macOS SwiftUI GUI for `yt-dlp`: video/audio from YouTube, Vimeo and 1,000+ sites. SwiftPM-only (swift-tools 6.0, macOS 15+), **zero external package dependencies**, builds with the Xcode Command Line Tools alone — no full Xcode, no XCTest, no SwiftData. v1.2.1, MIT, en/fr/ar localizations, self-updating from GitHub Releases.

## Architecture at a glance

Three targets, one-way dependencies:

```
DownstreamChecks (check runner, @testable ↓)
Downstream (SwiftUI app, @Observable models)  →  DownstreamCore (engine: no UI imports)
```

- **DownstreamCore** — `ProcessRunner` (shell-free process substrate), `ToolLocator`, `YtDlp/` (ArgumentBuilder, ProgressParser, MediaInfo, MetadataFetcher, PlaylistSelection, DownloadOptions), `Downloads/` (DownloadJob state machine, DownloadManager queue, PartialFiles cleanup, DownloadFormatting), `Persistence/` (Library over JSONFileStore), `Updates/` (AppUpdater, Changelog).
- **Downstream** — `AppDelegate` owns the models; `AppSettings` (UserDefaults namespace); 17 SwiftUI view files over `@MainActor @Observable` models, injected via `.environment`.
- **DownstreamChecks** — CLT-compatible check executable (`swift run DownstreamChecks`, `--live` for network suites); 331 checks as of this pass.

## What it excels at

1. **The CLT constraint is a feature, not a scar.** It is documented in Package.swift, README, DEVELOPMENT.md, and every workaround carries an inline rationale. The `@Observable`-without-macros pattern, the JSON persistence, and the custom check runner are all clean consequences of it.
2. **Genuinely layered core.** `DownstreamCore` imports only Foundation/CryptoKit/Observation/Synchronization. `ArgumentBuilder` is pure functions; parsing is replayable from fixtures; the checks run offline and hermetically (except `--live`).
3. **Modern Swift concurrency done carefully.** Swift 6 mode throughout: Sendable value types, `Mutex` (Synchronization), `AsyncThrowingStream` process output, blocking reads deliberately parked on a GCD utility queue so downloads can't starve the cooperative pool, ordered-progress guards on URLSession callbacks. One `@unchecked Sendable`, both justified in comments.
4. **Security posture well above par for this kind of app.** No shell is ever used for user input; `--` terminators; filename-template validation blocks path traversal; extra args go through a shell-like splitter that never spawns a shell; the self-updater verifies SHA-256 + codesign + bundle ID and stages the swap with rollback; unreadable data files are moved aside, never clobbered; all writes atomic.
5. **Product polish.** Partial-file cleanup on cancel, pause-preserves-partials, restore-on-relaunch, queue hold during yt-dlp updates, background-only notifications, RTL support, throttled progress, per-feature keyboard shortcuts.
6. **Documentation density.** Nearly every non-obvious line explains *why* (e.g. why `--no-mtime`, why remux is skipped for WebM, why `didSet` self-reassignment recurses under `@Observable`).

## Test status (after this pass)

| Suite | Result |
|---|---|
| `swift build` (Swift 6 strict concurrency) | clean — **zero compiler warnings** (the pre-existing 8 are fixed) |
| `swift run DownstreamChecks` (offline) | **325 passed** |
| `swift run DownstreamChecks --live` (real YouTube + GitHub) | **343 passed** incl. live on a calm network |
| `UNIVERSAL=1 scripts/bundle.sh release` | builds + signs (arm64 + x86_64) |
| GUI smoke test (dev copy, computer automation) | see below |

(Note: the live suite's subtitle-embedding check is network-dependent and flaked during later runs — the video CDN answers fine while YouTube's subtitle endpoint times out, or TLS connections to youtube.com reset outright (`SSL_ERROR_SYSCALL`). It passed on every run when the network was calm, including two full green runs. The download path it exercises was not modified by the fixes.)

GUI smoke test verified end-to-end: welcome guide (5 pages, legal notice), tool detection, add-download sheet (metadata → choices → download of "Me at the zoo"), queue transitions (downloading → completed), a forced failure appearing in History → Failed with working "Try again", the duplicate-link guard, quit-with-running-download (bounded wait, pending saved, no orphan process, no stray `.part` files), and relaunch restoring the paused download.

## Bugs fixed in the second pass (all with new checks)

1. **Cancel escalation ends at SIGKILL** — SIGINT → SIGTERM after `gracePeriod` → SIGKILL after another `gracePeriod` (SIGKILL can't be ignored), in both the async cancel and the blocking quit-time wait. Previously a process ignoring both signals ran forever while the UI showed Cancelled.
2. **Partial-file cleanup only deletes yt-dlp artifacts** — a cancelled download no longer removes user files that merely share the title prefix (`Title [id].nfo`, `.txt`, plain `.json`); deletion is restricted to known media/thumbnail/subtitle/partial extensions, `.part-Frag*`, and `.info.json`.
3. **Updater rollback failure is explicit** — if the staged move fails and the old version can't be restored from the Trash, the error now says the old version is in the Trash instead of a generic message.
4. **`relaunch()` watchdog is bounded** (30 s) and a failure to spawn the relauncher is surfaced in an alert instead of `try?` silence.
5. **Tool version probes run in parallel** — three hung tools no longer stack up to 30 s on every "Check again".
6. **Tool paths that point at directories are rejected** instead of failing confusingly at spawn.
7. **GitHub HTTP errors surface their status** (`requestFailed(status:)`, with a dedicated "rate-limited" message for 403) instead of a generic `URLError`.
8. **`withMountedImage` cleans up its temp mountpoint when `hdiutil attach` fails.**

## Bugs fixed in the first pass (all with new checks or GUI verification)

1. **Failed downloads never reached History** — `Library.record` was only called for `.completed`, leaving the History Failed tab permanently dead. Now both completed and failed jobs are recorded (the gate lives in `record`).
2. **Stale metadata fetch in the Add Download sheet** — editing the URL during a fetch didn't cancel it; you could download URL B with video A's metadata and options. Now the in-flight fetch is cancelled on edit and the result is dropped unless the URL still matches.
3. **Changelog parser broke on hyphenated versions** (`1.2.0-beta` parsed as version `1.2.0`, date `beta] - …`). Now the version is read from between the brackets.
4. **Quit could orphan yt-dlp/ffmpeg** — the app SIGINT'd children and died immediately; the SIGTERM escalation lived in a task that died with the app. New blocking `cancelAndWait(deadline:)` path from `applicationWillTerminate` (`DownloadManager.pauseAllAndWait`, 8s budget) waits for children before quitting.
5. **JSONFileStore backup-name collision** — two move-asides in the same ISO-8601 second made the second move fail silently, and the next save destroyed the unreadable file. Backup names now carry a UUID.
6. **Updater installed without verification when a release lacked a `.sha256` asset** — now fails closed with a dedicated `UpdateError.noChecksum`.
7. **Manual "Update yt-dlp Now" ignored running downloads** — now holds the queue, waits for running downloads (visible "Waiting…" status), then runs `brew upgrade`.
8. **A video URL with `&list=` downloaded the whole playlist** — metadata fetch now passes `--no-playlist` (pure playlist URLs unaffected).
9. **No duplicate-URL guard** — the same link into the same folder twice ran two yt-dlps over the same files. `DownloadManager.unfinishedJob(url:outputDirectory:)` now backs a blocker in the Add Download sheet and an alert for menu-bar quick downloads.

## Remaining known issues (not fixed, ordered by impact)

1. **aria2 downloads defeat cancel cleanup** — with aria2 the filename may never be reported, so `writtenFiles` stays empty and `.aria2`/`.part-Frag*` files survive cancel (cleanup is scoped per file name, and there's nothing to scope by).
2. **`ProcessRunner` drops the user's PATH** — deliberate for GUI apps, but wrapper-script overrides relying on pyenv-style shims break.
3. **`AppVersion` treats `1.2.0-beta` as equal to `1.2.0`** — a user on a published beta tag is never offered the final release. (Design choice: pre-release suffixes are ignored for ordering.)
4. **`MetadataFetcher.fetch()` has no offline check** (live-only); a check against a local yt-dlp fixture server would close the gap.

## Improvement opportunities

**Code health**
- `AppDelegate` is the de facto service locator: owns all models, wires them with five ad-hoc closures, plus a `static weak var shared` used across views. At this size it works; extracting an `AppContainer` or moving wiring into the models would keep it maintainable as features grow.
- `AppSettings` is global mutable static state with stringly-typed keys, and `SettingsModel` mirrors ~12 of them via `didSet` boilerplate — two parallel representations of settings.
- Small duplications: the "N downloading · N queued · speed" summary is built twice (`MainView.headerSummary`, `MenuBarView.summary`); the `circle()` icon-button helper exists twice; `LogSheet` calls into `DownloadRow.copy` (cross-view static coupling).
- `MainWindowModel` is a grab bag (filter + log sheet + history search + welcome + what's-new + menu-bar message).
- `Library.save` does synchronous pretty-printed encoding of up to 2000 history entries on the main actor on every queue change — move serialization off-main before the history grows.

**Testing / CI**
- The entire UI layer has zero automated coverage (executable targets can't be imported by the checks target). If UI models ever move into a library target, they become checkable; until then the GUI smoke test is manual/automation-only.
- CI never runs `--live`; a scheduled (weekly) live run would catch yt-dlp output-format drift early.
- No lint/format step (swiftlint/swift-format absent).
- `scripts/translations.py` isn't wired into CI — new UI strings silently fall back to English; a check comparing `Text`/`String(localized:)` keys against the generated tables would catch drift.
- The build shows ~19 pre-existing compiler warnings (isolation-related in `AppSettings`, a weak-capture mismatch in `AppUpdateModel`) — worth cleaning up once.

**Roadmap ideas (v1.3+)**
1. Subscribe to yt-dlp upstream releases for notifications independent of the weekly brew upgrade.
2. Clipboard watching as an opt-in alternative to manual paste-and-download.
3. Notarization for the published DMG (release.sh already supports the hooks).
4. Optional SwiftData/Swift Testing migration if the CLT constraint is ever dropped (full Xcode in CI).
5. Container/format presets per-site (e.g. remember "audio → m4a" for SoundCloud links).

## Repo housekeeping

- Git tree was clean at audit time; `.gitignore` covers all build artifacts. Two stale untracked artifacts on disk: `build/Downstream-1.1.0.dmg` (+`.sha256`) from a prior release, and `.DS_Store` files (ignored).
- `Support/en.lproj/Localizable.strings` being a single comment is intentional (English keys *are* the strings; fr/ar are generated).
- The DMG background's icon coordinates must be kept in sync by hand with `Support/dmg/settings.py` (`icon_locations`) — noted in the script; a comment cross-link would help.

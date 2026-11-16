import Foundation
import Observation

/// Starts a process. Injected so checks can replay recorded yt-dlp output instead of downloading.
public typealias ProcessStarter = @Sendable (URL, [String]) throws -> RunningProcess

/// One download and everything the UI shows about it. `DownloadManager` decides when it runs.
///
/// ```
/// queued ──run──▶ downloading ⇄ processing ──▶ completed
///   ▲ │              │    │                └─▶ failed ──retry──▶ queued
///   │ └─pause─▶ paused ◀──┘    └─cancel─▶ cancelled ──retry──▶ queued
///   └──resume──┘
/// ```
@MainActor
@Observable
public final class DownloadJob: Identifiable {
    public enum State: Equatable, Sendable {
        /// Waiting for a free slot.
        case queued
        /// nil progress means it's running but hasn't reported numbers (starting up, or aria2 is transferring).
        case downloading(DownloadProgress?)
        /// A post-processing step, already described for display.
        case processing(String)
        /// Stopped by the user. Partly downloaded files are kept, so resuming continues where it stopped.
        case paused
        case completed(URL)
        case failed(String)
        /// Stopped by the user; its partly downloaded files were deleted.
        case cancelled
    }

    public static let logLimit = 500

    public let id = UUID()
    public let url: URL
    public let options: DownloadOptions
    public let context: DownloadContext
    public let ytDlp: URL
    public let createdAt: Date
    public var title: String
    public var thumbnailURL: URL?

    public private(set) var state: State = .queued
    /// The most recent progress report, kept so a paused download can show how far it got.
    public private(set) var lastProgress: DownloadProgress?
    /// Every final file, in order. A playlist download produces one per item.
    public private(set) var savedFiles: [URL] = []
    /// Size of the last saved file, read when the job completes.
    public private(set) var savedFileSize: Int64?
    /// yt-dlp's output, minus progress lines, newest last. Shown when a download fails.
    public private(set) var log: [String] = []
    /// yt-dlp couldn't fetch the subtitles that were asked for; the video was saved without them.
    public private(set) var subtitlesMissing = false
    /// The subtitles couldn't be embedded, but a second try saved them as a file next to the video.
    public private(set) var subtitlesSavedSeparately = false
    /// Which automatic retry is waiting or starting (1 for the first), or nil when there's none.
    public private(set) var automaticRetry: Int?
    /// The download failed with no connection and is waiting for one to try again.
    public private(set) var waitingForNetwork = false
    /// Paused by Downstream because the download folder is gone (a drive was unplugged).
    public private(set) var folderUnavailable = false
    /// Playlist items that failed while others were saved.
    public private(set) var failedItems = 0

    /// How long to wait before each automatic retry of a temporary failure. Its count is the number of retries.
    nonisolated static let defaultRetryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
    var retryDelays = DownloadJob.defaultRetryDelays
    /// Whether the Mac has a network connection. `DownloadManager` supplies it.
    var isOnline: @MainActor () -> Bool = { true }
    /// While offline, a waiting download still tries this often, in case the system is wrong about the network.
    var offlineRetryInterval: Duration = .seconds(60)
    /// A download that has reported progress and then prints nothing for this long is restarted.
    var stallLimit: Duration = .seconds(300)
    /// How long after the video is saved the second try for refused subtitles starts.
    var subtitleRetryDelay: Duration = .seconds(15)
    /// A download doesn't start with less free space than this.
    var minimumFreeBytes: Int64 = 100_000_000

    private var process: RunningProcess?
    private var lastOutput = ContinuousClock.now
    private var stalled = false
    private var errorCount = 0
    private var stopRequest: StopRequest?
    private var lastError: String?
    /// When this attempt first started. Cleanup only deletes files written since then.
    private var firstStarted: Date?
    /// The files yt-dlp said it was writing, for cleanup on cancel.
    private var writtenFiles: Set<String> = []

    private enum StopRequest { case pause, cancel }

    public init(url: URL, options: DownloadOptions, context: DownloadContext, ytDlp: URL,
                title: String? = nil, thumbnailURL: URL? = nil) {
        self.url = url
        self.options = options
        self.context = context
        self.ytDlp = ytDlp
        self.title = title ?? url.absoluteString
        self.thumbnailURL = thumbnailURL
        self.createdAt = Date()
    }

    /// Brings back a download saved by `pendingSnapshot`: paused (resuming continues from its partial files),
    /// or failed with its message and log.
    public init(restoring saved: PendingDownload, tools: DownloadTools) {
        url = saved.url
        options = saved.options
        context = DownloadContext(url: saved.url, outputDirectory: saved.outputDirectory, ffmpeg: tools.ffmpeg, aria2c: tools.aria2c)
        ytDlp = tools.ytDlp
        title = saved.title
        thumbnailURL = saved.thumbnailURL
        createdAt = saved.createdAt
        if let failure = saved.failure {
            state = .failed(failure)
            log = saved.log ?? []
        } else {
            state = .paused
        }
        firstStarted = saved.startedAt
        writtenFiles = Set(saved.writtenFiles)
        lastProgress = saved.lastProgress.map { DownloadProgress(downloadedBytes: $0.downloadedBytes, totalBytes: $0.totalBytes) }
    }

    /// What to save so this download can be restored after a relaunch, or nil once it's completed or cancelled.
    /// A failed download is kept, with its log, so it can still be read and retried.
    public var pendingSnapshot: PendingDownload? {
        var failure: String?
        if case .failed(let message) = state { failure = message } else if isFinished { return nil }
        return PendingDownload(
            url: url, title: title, thumbnailURL: thumbnailURL, options: options,
            outputDirectory: context.outputDirectory, createdAt: createdAt,
            startedAt: firstStarted, writtenFiles: writtenFiles.sorted(),
            lastProgress: lastProgress.map { .init(downloadedBytes: $0.downloadedBytes, totalBytes: $0.totalBytes) },
            failure: failure, log: failure == nil ? nil : log)
    }

    /// yt-dlp is running for this job.
    public var isRunning: Bool {
        switch state {
        case .downloading, .processing: true
        default: false
        }
    }

    /// Completed, failed or cancelled: nothing more will happen unless it's retried.
    public var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    public var canPause: Bool {
        switch state {
        // Stopping ffmpeg halfway through a merge or conversion gains nothing; it finishes in seconds.
        case .queued, .downloading: true
        default: false
        }
    }

    public var canRetry: Bool {
        switch state {
        case .failed, .cancelled: true
        default: false
        }
    }

    // MARK: - Actions (called through DownloadManager, which schedules what runs)

    func pause() {
        switch state {
        case .queued: state = .paused
        case .downloading: stop(.pause)
        default: break
        }
    }

    /// Pauses, and if yt-dlp is running for this job, blocks the calling thread until it's gone
    /// (or `deadline` passes). Only for quitting: the app is about to die, and a child left
    /// running behind it would keep writing the file the next session would resume.
    func pauseAndWait(deadline: Duration) {
        switch state {
        case .downloading:
            stopRequest = .pause
            process?.cancelAndWait(deadline: deadline)
        default:
            pause()
        }
    }

    /// Paused → queued.
    func resume() {
        guard state == .paused else { return }
        folderUnavailable = false
        state = .queued
    }

    /// Failed or cancelled → queued, starting over. Partly downloaded files left by a failure are reused.
    func retry() {
        guard canRetry else { return }
        savedFiles = []
        savedFileSize = nil
        lastProgress = nil
        lastError = nil
        subtitlesMissing = false
        subtitlesSavedSeparately = false
        failedItems = 0
        log = []
        state = .queued
    }

    func cancel() {
        switch state {
        case .downloading, .processing:
            stop(.cancel)
        case .queued, .paused:
            deletePartialFiles()
            state = .cancelled
        case .completed, .failed, .cancelled:
            break
        }
    }

    private func stop(_ request: StopRequest) {
        stopRequest = request
        process?.cancel()
    }

    // MARK: - Running

    /// Runs the download until it completes, fails, or is paused or cancelled. Only starts a queued job.
    ///
    /// A failure isn't final straight away:
    /// - with the download folder gone, the job pauses instead (resuming tries again);
    /// - with no network, it waits for one, however long that takes;
    /// - if it looks temporary (see `isTemporary`) or the download stalled, it's retried after each of `retryDelays`.
    func run(starter: ProcessStarter) async {
        guard state == .queued else { return }
        stopRequest = nil
        guard folderIsAvailable else {
            folderUnavailable = true
            state = .paused
            return
        }
        if let free = freeBytes, free < minimumFreeBytes {
            state = .failed(String(localized: "The disk is almost full (\(DownloadFormatting.bytes(free)) free). Free up some space, then try again."))
            return
        }
        if firstStarted == nil { firstStarted = Date() }

        var retries = 0
        while true {
            state = .downloading(nil)
            let outcome = await attempt(starter: starter)
            guard case .failed(let message) = outcome, stopRequest == nil else {
                state = outcome
                break
            }
            guard folderIsAvailable else {
                folderUnavailable = true
                state = .paused
                break
            }
            let offline = !isOnline()
            guard offline || (retries < retryDelays.count && (stalled || Self.isTemporary(message))) else {
                state = finalState(afterFailure: message)
                break
            }

            lastError = nil
            state = .downloading(nil)
            if offline {
                waitingForNetwork = true
                appendLog("Downstream: no network; waiting for it to come back.")
                await wait(offlineRetryInterval) { self.isOnline() }
                waitingForNetwork = false
            } else {
                retries += 1
                automaticRetry = retries
                appendLog("Downstream: that looks temporary; trying again (\(retries) of \(retryDelays.count)).")
                await wait(retryDelays[retries - 1])
            }
            if let stopRequest {
                if stopRequest == .pause {
                    state = .paused
                } else {
                    deletePartialFiles()
                    state = .cancelled
                }
                break
            }
        }
        automaticRetry = nil

        if case .completed(let file) = state, subtitlesMissing, !options.downloadPlaylist {
            await retrySubtitles(starter: starter)
            state = .completed(file)
        }
        stopRequest = nil
    }

    /// What a failure that won't be retried ends as. A playlist that saved some of its items is complete,
    /// with the rest counted in `failedItems`: its files are there, and running it again skips them.
    private func finalState(afterFailure message: String) -> State {
        if options.downloadPlaylist, let file = savedFiles.last {
            failedItems = max(1, errorCount)
            savedFileSize = Self.size(of: file)
            return .completed(file)
        }
        return .failed(DownloadFormatting.failure(message))
    }

    /// Waits for `duration`, or less if `finished` turns true or the user pauses or cancels.
    private func wait(_ duration: Duration, until finished: () -> Bool = { false }) async {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end, stopRequest == nil, !finished() {
            try? await Task.sleep(for: min(.milliseconds(200), end - ContinuousClock.now))
        }
    }

    /// The download folder exists, creating it if it can be. False when its drive is unplugged.
    private var folderIsAvailable: Bool {
        let folder = context.outputDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var freeBytes: Int64? {
        (try? context.outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
    }

    private static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    /// One run of yt-dlp, and the state it ended in.
    private func attempt(starter: ProcessStarter) async -> State {
        let running: RunningProcess
        do {
            let arguments = try ArgumentBuilder.downloadArguments(options, context: context)
            running = try starter(ytDlp, arguments)
        } catch {
            return .failed(String(describing: error))
        }
        process = running
        errorCount = 0
        stalled = false
        lastOutput = .now
        let watchdog = stallWatchdog(for: running)
        defer {
            watchdog.cancel()
            process = nil
        }

        do {
            for try await line in running.lines {
                handle(ProgressParser.parse(line), raw: line.text)
            }
            guard let file = savedFiles.last else {
                return .failed(String(localized: "yt-dlp finished without saving a file."))
            }
            savedFileSize = Self.size(of: file)
            return .completed(file)
        } catch ProcessError.cancelled {
            if stalled { return .failed(String(localized: "The download stopped making progress.")) }
            if stopRequest == .pause { return .paused }
            deletePartialFiles()
            return .cancelled
        } catch ProcessError.failed(_, let stderrTail) {
            return .failed(lastError ?? MetadataFetcher.errorMessage(from: stderrTail))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Stops yt-dlp when a download that was reporting progress goes silent for `stallLimit`.
    /// Only then: starting up, converting, and aria2 (which reports nothing) are quiet for good reasons.
    private func stallWatchdog(for running: RunningProcess) -> Task<Void, Never> {
        Task { [weak self, interval = min(stallLimit / 4, .seconds(15))] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard case .downloading(.some) = state, stopRequest == nil,
                      ContinuousClock.now - lastOutput > stallLimit else { continue }
                stalled = true
                appendLog("Downstream: no progress for a while; restarting the download.")
                running.cancel()
                return
            }
        }
    }

    /// A second try for subtitles yt-dlp was refused (the video is already saved without them). They can't be
    /// embedded after the fact, so they're saved as a file next to the video, where players pick them up.
    private func retrySubtitles(starter: ProcessStarter) async {
        state = .processing(String(localized: "Getting subtitles"))
        await wait(subtitleRetryDelay)
        guard stopRequest == nil,
              let arguments = try? ArgumentBuilder.subtitleArguments(options, context: context),
              let running = try? starter(ytDlp, arguments) else { return }
        process = running
        defer { process = nil }

        let marker = "[info] Writing video subtitles to: "
        var written: [String] = []
        do {
            for try await line in running.lines {
                if line.text.hasPrefix(marker) { written.append(String(line.text.dropFirst(marker.count))) }
                appendLog(line.text)
            }
        } catch {
            return
        }
        let folder = context.outputDirectory
        if written.contains(where: { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0, relativeTo: folder).path) }) {
            subtitlesMissing = false
            subtitlesSavedSeparately = true
        }
    }

    /// Whether a yt-dlp error is worth trying again by itself: the site throttling or failing (429, 5xx)
    /// or the connection dropping. Anything else (unavailable, private, sign-in) needs the user.
    nonisolated static func isTemporary(_ message: String) -> Bool {
        let text = message.lowercased()
        let signs = [
            "http error 429", "too many requests",
            "http error 500", "http error 502", "http error 503", "http error 504",
            "timed out", "connection reset", "connection aborted", "remote end closed connection",
            "network is unreachable", "network is down", "nodename nor servname", "failed to resolve",
            "temporary failure in name resolution", "incompleteread",
        ]
        return signs.contains(where: text.contains)
    }

    private func handle(_ event: ProgressEvent, raw: String) {
        lastOutput = .now
        switch event {
        case .downloading(let progress):
            if let file = progress.filename { writtenFiles.insert(file) }
            lastProgress = progress
            if stopRequest == nil { state = .downloading(progress) }
            return  // too frequent to log
        case .downloadFinished(let file):
            if let file { writtenFiles.insert(file) }
            return  // a raw progress JSON line; the next step shows in the status
        case .postprocessing(let name):
            state = .processing(ProgressParser.describe(postprocessor: name))
        case .postprocessingFinished:
            break
        case .finalFile(let path):
            let file = URL(fileURLWithPath: path)
            if !savedFiles.contains(file) { savedFiles.append(file) }
        case .error(let message):
            lastError = message
            errorCount += 1
        case .warning(let message):
            if message.hasPrefix("Unable to download video subtitles") { subtitlesMissing = true }
        case .log:
            break
        }
        appendLog(raw)
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private func deletePartialFiles() {
        guard let since = firstStarted else { return }
        let removed = PartialFiles.remove(writtenBy: writtenFiles, in: context.outputDirectory, since: since,
                                          keeping: Set(savedFiles.map(\.path)))
        appendLog(removed.isEmpty
                  ? "Downstream: no partial files to delete (tracked \(writtenFiles.count) file(s))."
                  : "Downstream: deleted partial files: " + removed.joined(separator: ", "))
        writtenFiles = []
        firstStarted = nil
    }
}

/// Finds and deletes what a cancelled download left behind.
public enum PartialFiles {
    /// File extensions yt-dlp writes (media, thumbnails, subtitles, partials, control files).
    /// Cleanup only deletes prefix-matching files with one of these, so unrelated user files
    /// sharing the title (`Title [id].nfo`, `Title [id].txt`) survive a cancel.
    static let artifactExtensions: Set<String> = [
        "part", "ytdl", "aria2",                                        // partials and control files
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "3gp", "ts", "thp",  // video
        "m4a", "mp3", "opus", "ogg", "oga", "flac", "wav", "aac",       // audio
        "jpg", "jpeg", "png", "webp", "gif", "avif",                    // thumbnails
        "vtt", "srt", "sbv", "ssa", "ass", "lrc", "ttml",               // subtitles
        "description",                                                  // .description files
    ]

    /// True for names that look like what yt-dlp writes for this download.
    static func isArtifact(_ name: String) -> Bool {
        let `extension` = (name as NSString).pathExtension
        return artifactExtensions.contains(`extension`)
            || `extension`.hasPrefix("part-Frag")     // `Title.mp4.part-Frag3`
            || name.hasSuffix(".info.json")           // metadata; a plain `.json` is too broad
    }

    /// A file that reveals a download target without yt-dlp having reported it: aria2c's
    /// control file, or a transfer fragment of the target itself.
    static func isAria2Signal(_ name: String) -> Bool {
        name.hasSuffix(".aria2") || (name as NSString).pathExtension.hasPrefix("part-Frag")
    }

    /// For each file yt-dlp reported writing (e.g. `Title [id].f401.mp4`), deletes every file in `directory` that
    /// shares its base name (`Title [id].…`: `.part`, `.ytdl`, `.part-Frag3`, other formats, thumbnails, subtitles),
    /// looks like a yt-dlp artifact, and was modified at or after `since`. aria2c transfers report no file names
    /// at all, so when nothing was reported the `.aria2` control files newer than `since` identify the targets
    /// instead. Files outside `directory` and those in `keeping` are never touched. Returns the names it deleted.
    @discardableResult
    public static func remove(writtenBy files: Set<String>, in directory: URL, since: Date, keeping: Set<String>,
                              fileManager: FileManager = .default) -> [String] {
        // Compare folders with symlinks resolved: both exist, so both resolve the same way. (`standardizedFileURL`
        // drops `/private` from an existing `/private/tmp/…` folder but not from a file that doesn't exist yet.)
        let directoryPath = directory.resolvingSymlinksInPath().path
        var prefixes = Set(files.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == directoryPath else { return nil }
            return baseName(of: url.lastPathComponent) + "."
        })
        if let names = try? fileManager.contentsOfDirectory(atPath: directoryPath) {
            // A `.aria2` control file (or a bare `.part-Frag*` fragment) names its target, so it
            // scopes the cleanup even when yt-dlp never reported the file name. Only signals
            // newer than `since` count, so a stale control file from an earlier session is ignored.
            for name in names where isAria2Signal(name) {
                let path = (directoryPath as NSString).appendingPathComponent(name)
                guard let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      modified >= since.addingTimeInterval(-1)  // file systems round timestamps
                else { continue }
                prefixes.insert(baseName(of: name) + ".")
            }
        }
        guard !prefixes.isEmpty, let names = try? fileManager.contentsOfDirectory(atPath: directoryPath) else { return [] }
        var removed: [String] = []

        for name in names where prefixes.contains(where: { name.hasPrefix($0) || name + "." == $0 }) {
            guard isArtifact(name) else { continue }
            let path = (directoryPath as NSString).appendingPathComponent(name)
            guard !keeping.contains(path),
                  let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified >= since.addingTimeInterval(-1)  // file systems round timestamps
            else { continue }
            if (try? fileManager.removeItem(atPath: path)) != nil { removed.append(name) }
        }
        return removed.sorted()
    }

    /// `Title [id].f401.mp4` → `Title [id]`; `Title [id].mp4` → `Title [id]`.
    static func baseName(of fileName: String) -> String {
        var base = (fileName as NSString).deletingPathExtension
        let formatSuffix = (base as NSString).pathExtension
        if formatSuffix.hasPrefix("f"), formatSuffix.count > 1,
           formatSuffix.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            base = (base as NSString).deletingPathExtension
        }
        return base
    }
}

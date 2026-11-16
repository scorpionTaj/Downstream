import Foundation
import Observation

/// Starts a process. Injected so checks can replay recorded yt-dlp output instead of downloading.
public typealias ProcessStarter = @Sendable (URL, [String]) throws -> RunningProcess

/// Why Downstream paused a download by itself. Resuming tries again.
public enum PauseReason: String, Codable, Sendable {
    /// The download folder is gone (a drive was unplugged).
    case folderUnavailable
    /// The disk has no room for the rest of the download.
    case diskFull
}

/// How often, and how soon, a download that failed for a temporary reason is tried again.
public struct RetryPolicy: Codable, Sendable, Equatable {
    public static let countRange = 0...10
    public static let firstWaitChoices = [5, 15, 60]
    public static let `default` = RetryPolicy(count: 3, firstWaitSeconds: 5)

    public var count: Int
    public var firstWaitSeconds: Int

    public init(count: Int, firstWaitSeconds: Int) {
        self.count = min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound)
        self.firstWaitSeconds = max(1, firstWaitSeconds)
    }

    /// The wait before each retry: five times longer each time, up to ten minutes (5 s, 25 s, about 2 min, 10 min…).
    public var delays: [Duration] {
        var wait = firstWaitSeconds
        return (0..<count).map { _ in
            defer { wait = min(600, wait * 5) }
            return .seconds(wait)
        }
    }
}

/// One download and everything the UI shows about it. `DownloadManager` decides when it runs.
///
/// ```
/// queued ──run──▶ downloading ⇄ processing ──▶ completed
///   ▲ │  ◀─wait──┘   │    │                └─▶ failed ──retry──▶ queued
///   │ └─pause─▶ paused ◀──┘    └─cancel─▶ cancelled ──retry──▶ queued
///   └──resume──┘
/// ```
/// A failure that's worth trying again sends the job back to `queued` with a time to wait for (`isReadyToRun`),
/// so it doesn't hold a download slot while it waits.
@MainActor
@Observable
public final class DownloadJob: Identifiable {
    public enum State: Equatable, Sendable {
        /// Waiting for a free slot, for the network, or for the next automatic retry.
        case queued
        /// nil progress means it's running but hasn't reported numbers (starting up, or aria2 is transferring).
        case downloading(DownloadProgress?)
        /// A post-processing step, already described for display.
        case processing(String)
        /// Stopped by the user, or by Downstream (see `pauseReason`). Partly downloaded files are kept,
        /// so resuming continues where it stopped.
        case paused
        case completed(URL)
        case failed(String)
        /// Stopped by the user; its partly downloaded files were deleted.
        case cancelled
    }

    /// What became of subtitles yt-dlp was refused while the video itself was saved.
    public enum SubtitleStatus: Equatable, Sendable {
        /// The video has none (yet: see `recoverSubtitles`).
        case missing
        /// Another try is waiting or running.
        case retrying
        /// A later try got them, but they couldn't be put inside the video: they're in a file next to it.
        case separate
    }

    /// Subtitles still owed to one saved file.
    struct SubtitleDebt: Equatable {
        var file: URL
        /// The video's own page (not the playlist's).
        var url: String
        var languages: [String]
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
    /// nil when no subtitles are owed: none were asked for, or they're inside the video.
    public private(set) var subtitleStatus: SubtitleStatus?
    /// Which automatic retry is waiting or starting (1 for the first), or nil when there's none.
    public private(set) var automaticRetry: Int?
    /// The download failed with no connection and is waiting for one to try again.
    public private(set) var waitingForNetwork = false
    /// Set while `state` is `.paused` because Downstream paused it.
    public private(set) var pauseReason: PauseReason?
    /// Playlist items that failed while others were saved.
    public private(set) var failedItems = 0
    /// How many items the playlist download covers, once yt-dlp has said.
    public private(set) var playlistTotal: Int?

    /// How long to wait before each automatic retry of a temporary failure. Its count is the number of retries.
    var retryDelays = RetryPolicy.default.delays
    /// Whether the Mac has a network connection. `DownloadManager` supplies it.
    var isOnline: @MainActor () -> Bool = { true }
    /// While offline, a waiting download still tries this often, in case the system is wrong about the network.
    var offlineRetryInterval: Duration = .seconds(60)
    /// A download that has started writing and then shows no sign of life for this long is restarted.
    var stallLimit: Duration = .seconds(300)
    /// When the tries for refused subtitles happen, counted from when the video was saved or the last try.
    var subtitleRetryDelays: [Duration] = [.seconds(15), .seconds(120), .seconds(600)]
    /// A download doesn't start with less free space than this.
    var minimumFreeBytes: Int64 = 100_000_000

    private var process: RunningProcess?
    private var stopRequest: StopRequest?
    private var lastError: String?
    /// When this attempt first started. Cleanup only deletes files written since then.
    private var firstStarted: Date?
    /// The files yt-dlp said it was writing, for cleanup on cancel and for watching the download's size on disk.
    private var writtenFiles: Set<String> = []
    /// Automatic retries used since the user last started this download.
    private var retries = 0
    /// Earliest time the next automatic try may start.
    private var notBefore: ContinuousClock.Instant?
    /// Why Downstream itself stopped yt-dlp, when it did.
    private var interruption: Interruption?
    private var lastActivity = ContinuousClock.now
    private var lastFootprint = PartialFiles.Footprint()
    /// yt-dlp has started writing in this run, so silence from now on means something.
    private var sawActivity = false
    private var errorCount = 0
    /// The file whose size was last checked against the free space.
    private var spaceCheckedFor: String?
    /// Subtitle languages yt-dlp was refused for the item it's working on, until its file is known.
    private var refusedLanguages: [String] = []
    private var itemURL: String?
    private var subtitleDebts: [SubtitleDebt] = []
    private var subtitleTask: Task<Void, Never>?
    private var subtitleProcess: RunningProcess?
    /// Saved files already handed to history, so retrying a playlist's missing items doesn't list them twice.
    private var recordedFiles: Set<URL> = []
    /// Where yt-dlp notes the playlist items it has finished, so another run fetches only the rest.
    private let archive = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-archive-\(UUID().uuidString).txt")

    private enum StopRequest { case pause, cancel }
    private enum Interruption { case stalled, woke, diskFull }

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
            pauseReason = saved.pauseReason
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
            failure: failure, log: failure == nil ? nil : log, pauseReason: pauseReason)
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

    /// Queued, and not waiting for a retry time or the network that hasn't come yet.
    public var isReadyToRun: Bool {
        guard state == .queued else { return false }
        guard let notBefore else { return true }
        return ContinuousClock.now >= notBefore || (waitingForNetwork && isOnline())
    }

    /// When a queued job that's waiting may start, for `DownloadManager` to wake up at.
    var waitsUntil: ContinuousClock.Instant? { state == .queued ? notBefore : nil }

    public var canPause: Bool {
        switch state {
        // Stopping ffmpeg halfway through a merge or conversion gains nothing; it finishes in seconds.
        case .queued, .downloading: true
        default: false
        }
    }

    /// Failed and cancelled downloads start over; a playlist that saved only some items fetches the rest.
    public var canRetry: Bool {
        switch state {
        case .failed, .cancelled: true
        case .completed: failedItems > 0
        default: false
        }
    }

    /// Whether subtitles that were asked for are (still) not with the video.
    public var subtitlesMissing: Bool { subtitleStatus == .missing || subtitleStatus == .retrying }

    /// Saved files history hasn't been given yet.
    public var unrecordedFiles: [URL] { savedFiles.filter { !recordedFiles.contains($0) } }

    /// Whether `file` is still owed subtitles.
    public func owesSubtitles(for file: URL) -> Bool { subtitleDebts.contains { $0.file == file } }

    // MARK: - Actions (called through DownloadManager, which schedules what runs)

    func pause() {
        switch state {
        case .queued:
            stopWaiting()
            state = .paused
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
        pauseReason = nil
        retries = 0
        state = .queued
    }

    /// Failed or cancelled → queued, starting over. Partly downloaded files left by a failure are reused.
    /// A playlist with failed items keeps what it saved and goes back for the rest.
    func retry() {
        guard canRetry else { return }
        abandonSubtitles()
        if case .completed = state {
            failedItems = 0
        } else {
            savedFiles = []
            recordedFiles = []
            subtitleDebts = []
            subtitleStatus = nil
            savedFileSize = nil
            playlistTotal = nil
        }
        lastProgress = nil
        lastError = nil
        retries = 0
        log = []
        state = .queued
    }

    func cancel() {
        switch state {
        case .downloading, .processing:
            stop(.cancel)
        case .queued, .paused:
            stopWaiting()
            pauseReason = nil
            deletePartialFiles()
            state = .cancelled
        case .completed, .failed, .cancelled:
            break
        }
    }

    /// After the Mac wakes: a download that was running has a dead connection and often links that have
    /// expired, so it starts again (keeping what it has) instead of waiting for yt-dlp to give up on them.
    func restartAfterWake() {
        guard case .downloading = state, stopRequest == nil, interruption == nil, let process else { return }
        interruption = .woke
        appendLog("Downstream: the Mac woke up; restarting the download.")
        process.cancel()
    }

    /// History has been given every file saved so far.
    func markRecorded() { recordedFiles.formUnion(savedFiles) }

    private func stop(_ request: StopRequest) {
        stopRequest = request
        process?.cancel()
    }

    private func stopWaiting() {
        notBefore = nil
        waitingForNetwork = false
        automaticRetry = nil
    }

    // MARK: - Running

    /// Runs yt-dlp once. Only starts a queued job. It ends completed, failed, paused, cancelled — or queued again:
    /// - with the download folder gone or the disk full, the job pauses (resuming tries again);
    /// - with no network, it waits for one, however long that takes;
    /// - if the failure looks temporary (see `isTemporary`) or the download stalled, it waits for the next of `retryDelays`;
    /// - after the Mac woke up mid-download, it's ready again at once.
    func run(starter: ProcessStarter) async {
        guard state == .queued else { return }
        stopRequest = nil
        notBefore = nil
        waitingForNetwork = false
        guard folderIsAvailable else { return pause(because: .folderUnavailable) }
        if let free = freeBytes, free < minimumFreeBytes { return pause(because: .diskFull) }
        if firstStarted == nil { firstStarted = Date() }

        state = .downloading(nil)
        let outcome = await attempt(starter: starter)
        let interruption = interruption
        self.interruption = nil
        defer { stopRequest = nil }

        guard case .failed(let message) = outcome, stopRequest == nil else { return finish(outcome) }
        guard folderIsAvailable else { return pause(because: .folderUnavailable) }
        if message.lowercased().contains("no space left") { return pause(because: .diskFull) }

        lastError = nil
        if interruption == .woke {
            state = .queued
        } else if !isOnline() {
            waitingForNetwork = true
            notBefore = .now + offlineRetryInterval
            appendLog("Downstream: no network; waiting for it to come back.")
            state = .queued
        } else if retries < retryDelays.count, interruption == .stalled || Self.isTemporary(message) {
            retries += 1
            automaticRetry = retries
            notBefore = .now + retryDelays[retries - 1]
            appendLog("Downstream: that looks temporary; trying again (\(retries) of \(retryDelays.count)).")
            state = .queued
        } else {
            finish(finalState(afterFailure: message))
        }
    }

    private func finish(_ outcome: State) {
        automaticRetry = nil
        if case .completed = outcome {
            retries = 0
            subtitleStatus = subtitleDebts.isEmpty ? subtitleStatus : .missing
        }
        state = outcome
    }

    private func pause(because reason: PauseReason) {
        pauseReason = reason
        automaticRetry = nil
        state = .paused
    }

    /// What a failure that won't be retried ends as. A playlist that saved some of its items is complete,
    /// with the rest counted in `failedItems`: its files are there, and retrying fetches only the others.
    private func finalState(afterFailure message: String) -> State {
        if options.downloadPlaylist, let file = savedFiles.last {
            failedItems = max(1, errorCount)
            savedFileSize = Self.size(of: file)
            return .completed(file)
        }
        return .failed(DownloadFormatting.failure(message))
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
            var arguments = try ArgumentBuilder.downloadArguments(options, context: context)
            if options.downloadPlaylist {
                // Before the `--` that ends the options.
                arguments.insert(contentsOf: ["--download-archive", archive.path], at: arguments.count - 2)
            }
            running = try starter(ytDlp, arguments)
        } catch {
            return .failed(String(describing: error))
        }
        process = running
        errorCount = 0
        refusedLanguages = []
        itemURL = nil
        sawActivity = false
        spaceCheckedFor = nil
        lastActivity = .now
        lastFootprint = footprint
        let watchdog = watchdog(for: running)
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
            switch interruption {
            case .stalled: return .failed(String(localized: "The download stopped making progress."))
            case .woke: return .failed("Interrupted when the Mac went to sleep.")   // never shown: it restarts
            case .diskFull:
                pauseReason = .diskFull
                return .paused
            case nil: break
            }
            if stopRequest == .pause { return .paused }
            deletePartialFiles()
            return .cancelled
        } catch ProcessError.failed(_, let stderrTail) {
            return .failed(lastError ?? MetadataFetcher.errorMessage(from: stderrTail))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// What this download has on disk right now.
    private var footprint: PartialFiles.Footprint {
        guard let since = firstStarted else { return PartialFiles.Footprint() }
        return PartialFiles.footprint(writtenBy: writtenFiles, in: context.outputDirectory, since: since)
    }

    /// Watches a running yt-dlp and stops it when:
    /// - it shows no sign of life for `stallLimit` — no output and nothing changing on disk — after it had
    ///   started writing. Looking at the disk covers aria2, which reports nothing, and ffmpeg's conversions;
    /// - the disk can't hold the rest of the file being downloaded.
    private func watchdog(for running: RunningProcess) -> Task<Void, Never> {
        Task { [weak self, interval = min(stallLimit / 4, .seconds(15))] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard isRunning, stopRequest == nil, interruption == nil else { continue }
                if case .downloading(let progress?) = state, !hasRoom(for: progress) {
                    return interrupt(running, because: .diskFull)
                }
                let now = footprint
                if now != lastFootprint {
                    lastFootprint = now
                    lastActivity = .now
                    sawActivity = sawActivity || now.bytes > 0
                }
                if sawActivity, ContinuousClock.now - lastActivity > stallLimit {
                    return interrupt(running, because: .stalled)
                }
            }
        }
    }

    private func interrupt(_ running: RunningProcess, because reason: Interruption) {
        interruption = reason
        switch reason {
        case .stalled: appendLog("Downstream: no progress for a while; restarting the download.")
        case .diskFull: appendLog("Downstream: not enough disk space for the rest of this file; pausing.")
        case .woke: break
        }
        running.cancel()
    }

    /// Whether the disk can hold what's left of the file `progress` is about. True when its size isn't known.
    private func hasRoom(for progress: DownloadProgress) -> Bool {
        guard let total = progress.totalBytes, let free = freeBytes else { return true }
        return free >= total - progress.downloadedBytes
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
        lastActivity = .now
        switch event {
        case .downloading(let progress):
            if let file = progress.filename { writtenFiles.insert(file) }
            lastProgress = progress
            sawActivity = true
            if stopRequest == nil, interruption == nil {
                state = .downloading(progress)
                // As soon as a file's size is known, not only at the watchdog's next look.
                if progress.totalBytes != nil, progress.filename != spaceCheckedFor, let process {
                    spaceCheckedFor = progress.filename
                    if !hasRoom(for: progress) { interrupt(process, because: .diskFull) }
                }
            }
            return  // too frequent to log
        case .downloadFinished(let file):
            if let file { writtenFiles.insert(file) }
            return  // a raw progress JSON line; the next step shows in the status
        case .destination(let file, let playlistCount):
            // The only file name an aria2 transfer ever reports.
            writtenFiles.insert(file.hasPrefix("/") ? file : context.outputDirectory.appendingPathComponent(file).path)
            if options.downloadPlaylist, let playlistCount { playlistTotal = playlistCount }
            return
        case .itemURL(let url):
            itemURL = url
            return
        case .postprocessing(let name):
            if stopRequest == nil, interruption == nil { state = .processing(ProgressParser.describe(postprocessor: name)) }
        case .postprocessingFinished:
            break
        case .finalFile(let path):
            let file = URL(fileURLWithPath: path)
            if !savedFiles.contains(file) { savedFiles.append(file) }
            if !refusedLanguages.isEmpty {
                subtitleDebts.removeAll { $0.file == file }
                subtitleDebts.append(SubtitleDebt(file: file, url: itemURL ?? url.absoluteString, languages: refusedLanguages))
            }
            refusedLanguages = []
            itemURL = nil
        case .error(let message):
            lastError = message
            errorCount += 1
            refusedLanguages = []   // the item they were for didn't make it
        case .warning(let message):
            // "Unable to download video subtitles for 'ar': HTTP Error 429: Too Many Requests"
            let parts = message.split(separator: "'", omittingEmptySubsequences: false)
            if message.hasPrefix("Unable to download video subtitles"), parts.count >= 3 {
                refusedLanguages.append(String(parts[1]))
            }
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

    // MARK: - Subtitles yt-dlp was refused

    /// Tries again, after each of `subtitleRetryDelays`, for the subtitles yt-dlp was refused while it saved
    /// the videos, and puts them inside the videos — or next to them when ffmpeg can't. Runs after the download
    /// is complete and outside the download slots; `finished` is called when it's over, however it went.
    func recoverSubtitles(starter: @escaping ProcessStarter, finished: @escaping @MainActor () -> Void) {
        guard case .completed = state, !subtitleDebts.isEmpty, subtitleTask == nil else { return }
        subtitleStatus = .retrying
        subtitleTask = Task { [weak self] in
            var separate = false
            for delay in self?.subtitleRetryDelays ?? [] {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                for debt in subtitleDebts {
                    guard let embedded = await recover(debt, starter: starter), !Task.isCancelled else { continue }
                    subtitleDebts.removeAll { $0 == debt }
                    separate = separate || !embedded
                    if debt.file == savedFiles.last { savedFileSize = Self.size(of: debt.file) }
                }
                if subtitleDebts.isEmpty { break }
            }
            guard let self, !Task.isCancelled else { return }
            subtitleStatus = !subtitleDebts.isEmpty ? .missing : separate ? .separate : nil
            subtitleTask = nil
            finished()
        }
    }

    /// Stops trying for subtitles; what's still owed stays missing.
    func abandonSubtitles() {
        guard let subtitleTask else { return }
        subtitleTask.cancel()
        self.subtitleTask = nil
        subtitleProcess?.cancel()
        subtitleStatus = .missing
    }

    /// Fetches one file's subtitles into a scratch folder and adds them to the video.
    /// true: they're inside the video. false: they're in files next to it. nil: refused again.
    private func recover(_ debt: SubtitleDebt, starter: ProcessStarter) async -> Bool? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-subtitles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil,
              let running = try? starter(ytDlp, ArgumentBuilder.subtitleArguments(
                  options, url: debt.url, languages: debt.languages, directory: scratch))
        else { return nil }
        subtitleProcess = running
        defer { subtitleProcess = nil }
        do {
            for try await line in running.lines { appendLog(line.text) }
        } catch {
            return nil
        }

        let tracks = SubtitleEmbedder.tracks(in: scratch)
        guard !tracks.isEmpty else { return nil }
        if await SubtitleEmbedder.embed(tracks, into: debt.file, ffmpeg: context.ffmpeg) {
            appendLog("Downstream: added the subtitles to \(debt.file.lastPathComponent).")
            return true
        }
        // `Title.mp4` + Arabic → `Title.ar.vtt`, the name players look for.
        let base = debt.file.deletingPathExtension()
        var moved = false
        for track in tracks {
            let target = base.appendingPathExtension(track.language).appendingPathExtension(track.file.pathExtension)
            try? FileManager.default.removeItem(at: target)
            moved = (try? FileManager.default.moveItem(at: track.file, to: target)) != nil || moved
        }
        if moved { appendLog("Downstream: saved the subtitles next to \(debt.file.lastPathComponent).") }
        return moved ? false : nil
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
        let directoryPath = directory.resolvingSymlinksInPath().path
        var removed: [String] = []
        for name in artifacts(writtenBy: files, in: directory, since: since, fileManager: fileManager) {
            let path = (directoryPath as NSString).appendingPathComponent(name)
            guard !keeping.contains(path) else { continue }
            if (try? fileManager.removeItem(atPath: path)) != nil { removed.append(name) }
        }
        return removed.sorted()
    }

    /// How much a download has on disk, and when it last wrote: both stand still when it has stalled.
    public struct Footprint: Equatable, Sendable {
        public var bytes: Int64 = 0
        public var lastWrite: Date = .distantPast
    }

    /// The combined size and newest modification date of the download's files (see `remove` for which those are).
    public static func footprint(writtenBy files: Set<String>, in directory: URL, since: Date,
                                 fileManager: FileManager = .default) -> Footprint {
        let directoryPath = directory.resolvingSymlinksInPath().path
        var result = Footprint()
        for name in artifacts(writtenBy: files, in: directory, since: since, fileManager: fileManager) {
            let path = (directoryPath as NSString).appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { continue }
            result.bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            result.lastWrite = max(result.lastWrite, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        return result
    }

    /// The names of the download's files in `directory`, as `remove` describes them.
    static func artifacts(writtenBy files: Set<String>, in directory: URL, since: Date,
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
        return names.filter { name in
            guard prefixes.contains(where: { name.hasPrefix($0) || name + "." == $0 }), isArtifact(name) else { return false }
            let path = (directoryPath as NSString).appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
            return modified >= since.addingTimeInterval(-1)  // file systems round timestamps
        }
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

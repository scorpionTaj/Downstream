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

    private var process: RunningProcess?
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

    /// Brings back a download saved by `pendingSnapshot`, paused. Resuming continues from its partial files.
    public init(restoring saved: PendingDownload, tools: DownloadTools) {
        url = saved.url
        options = saved.options
        context = DownloadContext(url: saved.url, outputDirectory: saved.outputDirectory, ffmpeg: tools.ffmpeg, aria2c: tools.aria2c)
        ytDlp = tools.ytDlp
        title = saved.title
        thumbnailURL = saved.thumbnailURL
        createdAt = saved.createdAt
        state = .paused
        firstStarted = saved.startedAt
        writtenFiles = Set(saved.writtenFiles)
        lastProgress = saved.lastProgress.map { DownloadProgress(downloadedBytes: $0.downloadedBytes, totalBytes: $0.totalBytes) }
    }

    /// What to save so this download can be restored after a relaunch, or nil once it's finished.
    public var pendingSnapshot: PendingDownload? {
        guard !isFinished else { return nil }
        return PendingDownload(
            url: url, title: title, thumbnailURL: thumbnailURL, options: options,
            outputDirectory: context.outputDirectory, createdAt: createdAt,
            startedAt: firstStarted, writtenFiles: writtenFiles.sorted(),
            lastProgress: lastProgress.map { .init(downloadedBytes: $0.downloadedBytes, totalBytes: $0.totalBytes) })
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

    /// Paused → queued.
    func resume() {
        if state == .paused { state = .queued }
    }

    /// Failed or cancelled → queued, starting over. Partly downloaded files left by a failure are reused.
    func retry() {
        guard canRetry else { return }
        savedFiles = []
        savedFileSize = nil
        lastProgress = nil
        lastError = nil
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
    func run(starter: ProcessStarter) async {
        guard state == .queued else { return }
        state = .downloading(nil)
        stopRequest = nil
        if firstStarted == nil { firstStarted = Date() }

        do {
            let arguments = try ArgumentBuilder.downloadArguments(options, context: context)
            process = try starter(ytDlp, arguments)
        } catch {
            state = .failed(String(describing: error))
            return
        }

        do {
            for try await line in process!.lines {
                handle(ProgressParser.parse(line), raw: line.text)
            }
            if let file = savedFiles.last {
                savedFileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                state = .completed(file)
            } else {
                state = .failed(String(localized: "yt-dlp finished without saving a file."))
            }
        } catch ProcessError.cancelled {
            if stopRequest == .pause {
                state = .paused
            } else {
                deletePartialFiles()
                state = .cancelled
            }
        } catch ProcessError.failed(_, let stderrTail) {
            state = .failed(lastError ?? MetadataFetcher.errorMessage(from: stderrTail))
        } catch {
            state = .failed(String(describing: error))
        }
        process = nil
        stopRequest = nil
    }

    private func handle(_ event: ProgressEvent, raw: String) {
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
        case .warning, .log:
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
    /// For each file yt-dlp reported writing (e.g. `Title [id].f401.mp4`), deletes every file in `directory` that
    /// shares its base name (`Title [id].…`: `.part`, `.ytdl`, `.part-Frag3`, other formats, thumbnails, subtitles)
    /// and was modified at or after `since`. Files outside `directory` and those in `keeping` are never touched.
    /// Returns the names it deleted.
    @discardableResult
    public static func remove(writtenBy files: Set<String>, in directory: URL, since: Date, keeping: Set<String>,
                              fileManager: FileManager = .default) -> [String] {
        // Compare folders with symlinks resolved: both exist, so both resolve the same way. (`standardizedFileURL`
        // drops `/private` from an existing `/private/tmp/…` folder but not from a file that doesn't exist yet.)
        let directoryPath = directory.resolvingSymlinksInPath().path
        let prefixes = Set(files.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == directoryPath else { return nil }
            return baseName(of: url.lastPathComponent) + "."
        })
        guard !prefixes.isEmpty, let names = try? fileManager.contentsOfDirectory(atPath: directoryPath) else { return [] }
        var removed: [String] = []

        for name in names where prefixes.contains(where: name.hasPrefix) {
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

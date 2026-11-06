import Foundation
import Observation

/// The tools a download needs, resolved by `ToolLocator`.
public struct DownloadTools: Sendable, Equatable {
    public var ytDlp: URL
    public var ffmpeg: URL
    public var aria2c: URL?

    public init(ytDlp: URL, ffmpeg: URL, aria2c: URL? = nil) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.aria2c = aria2c
    }

    /// nil unless both required tools were found.
    public init?(report: ToolReport) {
        guard let ytDlp = report[.ytDlp]?.url, let ffmpeg = report[.ffmpeg]?.url else { return nil }
        self.init(ytDlp: ytDlp, ffmpeg: ffmpeg, aria2c: report[.aria2c]?.url)
    }
}

/// Owns every download in this session and runs at most `maxConcurrent` at once, oldest first.
@MainActor
@Observable
public final class DownloadManager {
    public nonisolated static let defaultMaxConcurrent = 3

    /// Newest first.
    public private(set) var jobs: [DownloadJob] = []

    /// Raising it starts queued downloads right away; lowering it lets running ones finish.
    public var maxConcurrent: Int {
        get { concurrencyLimit }
        set {
            // Not a didSet that reassigns itself: @Observable turns stored properties into computed ones,
            // so that would recurse forever.
            concurrencyLimit = max(1, newValue)
            schedule()
        }
    }
    private var concurrencyLimit: Int

    /// Called once each time a job completes or fails (not when it's paused or cancelled).
    public var onJobFinished: ((DownloadJob) -> Void)?
    /// Called after anything that changes which downloads are unfinished, so they can be saved.
    public var onQueueChanged: (() -> Void)?

    private let starter: ProcessStarter
    /// Jobs handed to a run task. Tracked separately from `state`, which only changes once the task starts.
    private var started: Set<UUID> = []

    public init(maxConcurrent: Int = DownloadManager.defaultMaxConcurrent,
                starter: @escaping ProcessStarter = { try ProcessRunner.start($0, arguments: $1) }) {
        self.concurrencyLimit = max(1, maxConcurrent)
        self.starter = starter
    }

    public var runningCount: Int { started.count }
    public var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    /// Jobs that would be lost if the app quit now: running, queued or paused.
    public var unfinishedCount: Int { jobs.filter { !$0.isFinished }.count }

    /// Bytes per second across every running download.
    public var totalSpeed: Double {
        jobs.reduce(0) { total, job in
            if case .downloading(let progress?) = job.state { total + (progress.speed ?? 0) } else { total }
        }
    }

    /// Adds a download to the queue; it starts as soon as a slot is free.
    @discardableResult
    public func add(url: URL, options: DownloadOptions, title: String?, thumbnailURL: URL?,
                    outputDirectory: URL, tools: DownloadTools) -> DownloadJob {
        let context = DownloadContext(url: url, outputDirectory: outputDirectory, ffmpeg: tools.ffmpeg, aria2c: tools.aria2c)
        let job = DownloadJob(url: url, options: options, context: context, ytDlp: tools.ytDlp,
                              title: title, thumbnailURL: thumbnailURL)
        jobs.insert(job, at: 0)
        schedule()
        onQueueChanged?()
        return job
    }

    public func pause(_ job: DownloadJob) {
        job.pause()
        onQueueChanged?()
    }

    public func resume(_ job: DownloadJob) {
        job.resume()
        schedule()
        onQueueChanged?()
    }

    public func retry(_ job: DownloadJob) {
        job.retry()
        schedule()
        onQueueChanged?()
    }

    public func cancel(_ job: DownloadJob) {
        job.cancel()
        schedule()
        onQueueChanged?()
    }

    /// Removes a job from the list. A queued or paused one is cancelled first (deleting its partial files);
    /// a running one must be stopped first.
    public func remove(_ job: DownloadJob) {
        guard !started.contains(job.id) else { return }
        if !job.isFinished { job.cancel() }
        jobs.removeAll { $0.id == job.id }
        onQueueChanged?()
    }

    public func removeFinished() {
        jobs.removeAll { $0.isFinished }
    }

    /// Unfinished downloads, oldest first, for saving.
    public var pendingDownloads: [PendingDownload] { jobs.reversed().compactMap(\.pendingSnapshot) }

    /// Adds downloads saved at the last quit, paused, below anything already in the list.
    public func restore(_ pending: [PendingDownload], tools: DownloadTools) {
        let restored = pending.reversed().map { DownloadJob(restoring: $0, tools: tools) }
        jobs.append(contentsOf: restored)
    }

    /// Queues a new download with the same link and options as a finished one.
    @discardableResult
    public func downloadAgain(_ entry: HistoryEntry, outputDirectory: URL, tools: DownloadTools) -> DownloadJob {
        add(url: entry.url, options: entry.options, title: entry.title, thumbnailURL: entry.thumbnailURL,
            outputDirectory: outputDirectory, tools: tools)
    }

    /// Pauses everything, keeping partial files. Used when the app quits.
    public func pauseAll() {
        for job in jobs { job.pause() }
    }

    public func cancelAll() {
        for job in jobs { job.cancel() }
    }

    /// Starts the oldest queued jobs until `maxConcurrent` are running.
    private func schedule() {
        // `jobs` is newest first, so walk it backwards.
        for job in jobs.reversed() where started.count < maxConcurrent {
            guard job.state == .queued, !started.contains(job.id) else { continue }
            started.insert(job.id)
            let starter = starter
            Task {
                try? FileManager.default.createDirectory(at: job.context.outputDirectory, withIntermediateDirectories: true)
                await job.run(starter: starter)
                started.remove(job.id)
                switch job.state {
                case .completed, .failed: onJobFinished?(job)
                default: break
                }
                schedule()
                onQueueChanged?()
            }
        }
    }
}

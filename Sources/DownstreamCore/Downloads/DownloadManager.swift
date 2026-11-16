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
    /// Called when the later tries for a finished job's refused subtitles are over.
    public var onSubtitlesRecovered: ((DownloadJob) -> Void)?

    /// How temporary failures are tried again. Applies to every download, including ones already listed.
    public var retryPolicy = RetryPolicy.default {
        didSet { for job in jobs { job.retryDelays = retryPolicy.delays } }
    }

    /// While true, queued downloads wait (e.g. while yt-dlp itself is being updated). Running ones carry on.
    public var isHeld = false {
        didSet { if !isHeld { schedule() } }
    }

    /// Whether the Mac has a network connection (the app watches it). Offline, a failing download waits
    /// for the connection instead of failing; it starts again as soon as this turns true.
    public var isOnline = true {
        didSet { if isOnline { schedule() } }
    }

    /// Wakes `schedule()` when the next waiting download is due.
    private var wake: Task<Void, Never>?

    /// Held while downloads run, so the Mac doesn't fall asleep in the middle of one.
    private var awake: NSObjectProtocol?

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

    /// The unfinished download for this exact link and folder, if there is one: adding it again
    /// would run two yt-dlps over the same output files.
    public func unfinishedJob(url: URL, outputDirectory: URL) -> DownloadJob? {
        jobs.first { $0.url == url && $0.context.outputDirectory == outputDirectory && !$0.isFinished }
    }

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
        adopt(job)
        jobs.insert(job, at: 0)
        schedule()
        onQueueChanged?()
        return job
    }

    private func adopt(_ job: DownloadJob) {
        job.isOnline = { [weak self] in self?.isOnline ?? true }
        job.retryDelays = retryPolicy.delays
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
        job.abandonSubtitles()
        jobs.removeAll { $0.id == job.id }
        onQueueChanged?()
    }

    public func removeFinished() {
        for job in jobs where job.isFinished { job.abandonSubtitles() }
        jobs.removeAll { $0.isFinished }
        onQueueChanged?()   // failed downloads are saved too
    }

    /// Unfinished downloads, oldest first, for saving.
    public var pendingDownloads: [PendingDownload] { jobs.reversed().compactMap(\.pendingSnapshot) }

    /// Adds downloads saved at the last quit (paused, or failed as they were) below anything already in the list.
    public func restore(_ pending: [PendingDownload], tools: DownloadTools) {
        let restored = pending.reversed().map { DownloadJob(restoring: $0, tools: tools) }
        restored.forEach(adopt)
        jobs.append(contentsOf: restored)
    }

    /// Queues a new download with the same link and options as a finished one.
    @discardableResult
    public func downloadAgain(_ entry: HistoryEntry, outputDirectory: URL, tools: DownloadTools) -> DownloadJob {
        add(url: entry.url, options: entry.options, title: entry.title, thumbnailURL: entry.thumbnailURL,
            outputDirectory: outputDirectory, tools: tools)
    }

    public var pausedCount: Int { jobs.filter { $0.state == .paused }.count }
    public var failedCount: Int { jobs.filter { if case .failed = $0.state { true } else { false } }.count }

    public func resumeAll() {
        for job in jobs where job.state == .paused { job.resume() }
        schedule()
        onQueueChanged?()
    }

    /// Retries every failed download (cancelled ones stay cancelled).
    public func retryFailed() {
        for job in jobs { if case .failed = job.state { job.retry() } }
        schedule()
        onQueueChanged?()
    }

    /// Pauses everything, keeping partial files. Used when the app quits.
    public func pauseAll() {
        for job in jobs { job.pause() }
        onQueueChanged?()
    }

    /// `pauseAll()` that also waits for the child processes, bounded by `deadline` in total:
    /// after `applicationWillTerminate` returns the app dies, and a yt-dlp left running could
    /// keep writing the file the next session would resume.
    public func pauseAllAndWait(deadline: Duration = .seconds(8)) {
        let end = ContinuousClock.now + deadline
        for job in jobs {
            let remaining = end - ContinuousClock.now
            guard remaining > .zero else { break }
            job.pauseAndWait(deadline: remaining)
        }
        onQueueChanged?()
    }

    /// Call when the Mac wakes from sleep: running downloads start again from what they have.
    public func restartAfterWake() {
        for job in jobs { job.restartAfterWake() }
    }

    public func cancelAll() {
        for job in jobs { job.cancel() }
        onQueueChanged?()
    }

    private func keepAwakeWhileRunning() {
        if started.isEmpty {
            if let awake { ProcessInfo.processInfo.endActivity(awake) }
            awake = nil
        } else if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Downloading")
        }
    }

    /// Starts the oldest queued jobs that are ready until `maxConcurrent` are running. A job waiting for its
    /// next automatic retry or for the network is queued but not ready: it holds no slot, and `wake` comes
    /// back for it when it's due.
    private func schedule() {
        guard !isHeld else { return }
        // `jobs` is newest first, so walk it backwards.
        for job in jobs.reversed() where started.count < maxConcurrent {
            guard job.isReadyToRun, !started.contains(job.id) else { continue }
            started.insert(job.id)
            keepAwakeWhileRunning()
            let starter = starter
            Task {
                await job.run(starter: starter)
                started.remove(job.id)
                keepAwakeWhileRunning()
                switch job.state {
                case .completed, .failed:
                    onJobFinished?(job)
                    job.markRecorded()
                    job.recoverSubtitles(starter: starter) { self.onSubtitlesRecovered?(job) }
                default: break
                }
                schedule()
                onQueueChanged?()
            }
        }

        wake?.cancel()
        wake = nil
        if let next = jobs.compactMap(\.waitsUntil).min() {
            wake = Task { [weak self] in
                try? await Task.sleep(until: next, clock: .continuous)
                if !Task.isCancelled { self?.schedule() }
            }
        }
    }
}

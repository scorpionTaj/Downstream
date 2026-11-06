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

/// Owns every download in this session. Milestone 4 adds the queue: a concurrency limit, pause, resume and retry.
@MainActor
@Observable
public final class DownloadManager {
    /// Newest first.
    public private(set) var jobs: [DownloadJob] = []
    private let starter: ProcessStarter

    public init(starter: @escaping ProcessStarter = { try ProcessRunner.start($0, arguments: $1) }) {
        self.starter = starter
    }

    public var activeCount: Int { jobs.filter(\.isActive).count }

    /// Bytes per second across every running download.
    public var totalSpeed: Double {
        jobs.reduce(0) { total, job in
            if case .downloading(let progress?) = job.state { total + (progress.speed ?? 0) } else { total }
        }
    }

    /// Adds a download and starts it. The output folder is created if it doesn't exist.
    @discardableResult
    public func add(url: URL, options: DownloadOptions, title: String?, thumbnailURL: URL?,
                    outputDirectory: URL, tools: DownloadTools) -> DownloadJob {
        let job = DownloadJob(url: url, options: options, title: title, thumbnailURL: thumbnailURL)
        jobs.insert(job, at: 0)
        let context = DownloadContext(url: url, outputDirectory: outputDirectory, ffmpeg: tools.ffmpeg, aria2c: tools.aria2c)
        let starter = starter
        Task {
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            } catch {
                // Let the job report it: yt-dlp fails with a clear message when it can't write there.
            }
            await job.run(context: context, ytDlp: tools.ytDlp, starter: starter)
        }
        return job
    }

    /// Removes a finished job from the list. Active jobs must be cancelled first.
    public func remove(_ job: DownloadJob) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
    }

    public func removeFinished() {
        jobs.removeAll { !$0.isActive }
    }

    public func cancelAll() {
        for job in jobs where job.isActive { job.cancel() }
    }
}

import Foundation
import Observation

/// Starts a process. Injected so checks can replay recorded yt-dlp output instead of downloading.
public typealias ProcessStarter = @Sendable (URL, [String]) throws -> RunningProcess

/// One download and everything the UI shows about it.
@MainActor
@Observable
public final class DownloadJob: Identifiable {
    public enum State: Equatable, Sendable {
        case waiting
        /// nil progress means it's running but hasn't reported numbers (starting up, or aria2 is transferring).
        case downloading(DownloadProgress?)
        /// A post-processing step, already described for display.
        case processing(String)
        case completed(URL)
        case failed(String)
        case cancelled
    }

    public static let logLimit = 500

    public let id = UUID()
    public let url: URL
    public let options: DownloadOptions
    public let createdAt = Date()
    public var title: String
    public var thumbnailURL: URL?

    public private(set) var state: State = .waiting
    /// Every final file, in order. A playlist download produces one per item.
    public private(set) var savedFiles: [URL] = []
    /// Size of the last saved file, read when the job completes.
    public private(set) var savedFileSize: Int64?
    /// yt-dlp's output, minus progress lines, newest last. Shown when a download fails.
    public private(set) var log: [String] = []

    private var process: RunningProcess?
    private var lastError: String?

    public init(url: URL, options: DownloadOptions, title: String? = nil, thumbnailURL: URL? = nil) {
        self.url = url
        self.options = options
        self.title = title ?? url.absoluteString
        self.thumbnailURL = thumbnailURL
    }

    public var isActive: Bool {
        switch state {
        case .waiting, .downloading, .processing: true
        case .completed, .failed, .cancelled: false
        }
    }

    /// Stops the download, or marks it cancelled if it hasn't started.
    public func cancel() {
        if let process {
            process.cancel()
        } else if state == .waiting {
            state = .cancelled
        }
    }

    /// Runs the download to the end. Returns once it has completed, failed or been cancelled.
    public func run(context: DownloadContext, ytDlp: URL, starter: ProcessStarter = { try ProcessRunner.start($0, arguments: $1) }) async {
        guard state == .waiting else { return }
        state = .downloading(nil)

        let arguments: [String]
        do {
            arguments = try ArgumentBuilder.downloadArguments(options, context: context)
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
                state = .failed("yt-dlp finished without saving a file.")
            }
        } catch ProcessError.cancelled {
            state = .cancelled
        } catch ProcessError.failed(_, let stderrTail) {
            state = .failed(lastError ?? MetadataFetcher.errorMessage(from: stderrTail))
        } catch {
            state = .failed(String(describing: error))
        }
        process = nil
    }

    private func handle(_ event: ProgressEvent, raw: String) {
        switch event {
        case .downloading(let progress):
            state = .downloading(progress)
            return  // too frequent to log
        case .downloadFinished:
            return  // a raw progress JSON line; the next step shows in the status
        case .postprocessing(let name):
            state = .processing(ProgressParser.describe(postprocessor: name))
        case .postprocessingFinished:
            break
        case .finalFile(let path):
            savedFiles.append(URL(fileURLWithPath: path))
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
}

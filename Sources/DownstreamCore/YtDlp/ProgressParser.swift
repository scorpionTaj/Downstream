import Foundation

/// Byte-level progress of the file being downloaded.
public struct DownloadProgress: Sendable, Equatable {
    public var downloadedBytes: Int64
    /// Exact size, or yt-dlp's estimate when only that is known.
    public var totalBytes: Int64?
    /// Bytes per second.
    public var speed: Double?
    /// Seconds left.
    public var eta: Double?
    /// For HLS/DASH downloads, which arrive in fragments.
    public var fragmentIndex: Int?
    public var fragmentCount: Int?
    /// Where yt-dlp is writing, e.g. the video or the audio part of a merged download.
    public var filename: String?

    /// 0...1, or nil when the size is unknown.
    public var fraction: Double? {
        if let total = totalBytes, total > 0 { return min(1, Double(downloadedBytes) / Double(total)) }
        if let index = fragmentIndex, let count = fragmentCount, count > 0 { return min(1, Double(index) / Double(count)) }
        return nil
    }
}

/// What one line of yt-dlp output means.
public enum ProgressEvent: Sendable, Equatable {
    case downloading(DownloadProgress)
    /// One file finished downloading. A video with separate audio sends this twice before merging.
    case downloadFinished(filename: String?)
    /// A post-processing step started (merging, converting, embedding…). `name` is yt-dlp's postprocessor name.
    case postprocessing(name: String)
    case postprocessingFinished(name: String)
    /// The final file, after every step and move.
    case finalFile(path: String)
    case warning(String)
    case error(String)
    /// Anything else, kept for the job's log.
    case log(String)
}

public enum ProgressParser {
    public static func parse(_ line: OutputLine) -> ProgressEvent { parse(line.text) }

    public static func parse(_ line: String) -> ProgressEvent {
        if line.hasPrefix(ArgumentBuilder.downloadProgressPrefix) {
            return parseDownload(json: line.dropFirst(ArgumentBuilder.downloadProgressPrefix.count)) ?? .log(line)
        }
        if line.hasPrefix(ArgumentBuilder.postprocessProgressPrefix) {
            return parsePostprocess(json: line.dropFirst(ArgumentBuilder.postprocessProgressPrefix.count)) ?? .log(line)
        }
        if line.hasPrefix(ArgumentBuilder.finalFilePrefix) {
            return .finalFile(path: String(line.dropFirst(ArgumentBuilder.finalFilePrefix.count)))
        }
        if line.hasPrefix("ERROR:") {
            return .error(line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("WARNING:") {
            return .warning(line.dropFirst("WARNING:".count).trimmingCharacters(in: .whitespaces))
        }
        return .log(line)
    }

    /// A short, human description of a postprocessor, for the status line.
    public static func describe(postprocessor name: String) -> String {
        switch name {
        case "Merger": "Merging video and audio"
        case "ExtractAudio": "Converting audio"
        case "VideoRemuxer", "VideoConvertor": "Converting video"
        case "EmbedSubtitle": "Embedding subtitles"
        case "EmbedThumbnail": "Embedding thumbnail"
        case "Metadata": "Adding metadata"
        case "SponsorBlock": "Finding SponsorBlock segments"
        case "ModifyChapters": "Removing SponsorBlock segments"
        case "MoveFiles": "Finishing up"
        default: "Processing (\(name))"
        }
    }

    private struct DownloadPayload: Decodable {
        var status: String?
        var downloaded_bytes: Double?
        var total_bytes: Double?
        var total_bytes_estimate: Double?
        var speed: Double?
        var eta: Double?
        var fragment_index: Int?
        var fragment_count: Int?
        var filename: String?
    }

    private struct PostprocessPayload: Decodable {
        var status: String?
        var postprocessor: String?
    }

    private static func parseDownload(json: Substring) -> ProgressEvent? {
        guard let payload = try? JSONDecoder().decode(DownloadPayload.self, from: Data(json.utf8)) else { return nil }
        switch payload.status {
        case "finished":
            return .downloadFinished(filename: payload.filename)
        case "error":
            return .error("Download failed")
        default:
            return .downloading(DownloadProgress(
                downloadedBytes: Int64(payload.downloaded_bytes ?? 0),
                totalBytes: (payload.total_bytes ?? payload.total_bytes_estimate).map { Int64($0) },
                speed: payload.speed,
                eta: payload.eta,
                fragmentIndex: payload.fragment_index,
                fragmentCount: payload.fragment_count,
                filename: payload.filename))
        }
    }

    private static func parsePostprocess(json: Substring) -> ProgressEvent? {
        guard let payload = try? JSONDecoder().decode(PostprocessPayload.self, from: Data(json.utf8)),
              let name = payload.postprocessor
        else { return nil }
        return payload.status == "finished" ? .postprocessingFinished(name: name) : .postprocessing(name: name)
    }
}

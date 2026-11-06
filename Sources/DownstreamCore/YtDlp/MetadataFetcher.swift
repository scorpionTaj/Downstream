import Foundation

public enum MetadataError: Error, Equatable, CustomStringConvertible {
    /// yt-dlp failed. `message` is its `ERROR:` line when there was one, without the prefix.
    case ytDlpFailed(message: String)
    /// yt-dlp succeeded but printed something that isn't the expected JSON.
    case unreadableOutput

    public var description: String {
        switch self {
        case .ytDlpFailed(let message): message
        case .unreadableOutput: String(localized: "yt-dlp returned information Downstream couldn't read.")
        }
    }
}

/// Asks yt-dlp what a URL contains, without downloading it.
public struct MetadataFetcher: Sendable {
    public let ytDlp: URL

    public init(ytDlp: URL) { self.ytDlp = ytDlp }

    /// Playlists come back flat (entries only, not each video's formats), so a 500-item playlist stays fast.
    public func fetch(_ url: URL, cookies: CookieSource? = nil, timeout: Duration = .seconds(90)) async throws -> MediaInfo {
        let arguments = ArgumentBuilder.metadataArguments(for: url, cookies: cookies)
        let json: String
        do {
            json = try await ProcessRunner.output(of: ytDlp, arguments: arguments, timeout: timeout)
        } catch ProcessError.failed(_, let tail) {
            throw MetadataError.ytDlpFailed(message: Self.errorMessage(from: tail))
        }
        do {
            return try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        } catch {
            throw MetadataError.unreadableOutput
        }
    }

    /// The most useful line of yt-dlp's stderr: its last `ERROR:` line, else its last line.
    static func errorMessage(from stderrTail: [String]) -> String {
        if let line = stderrTail.last(where: { $0.hasPrefix("ERROR:") }) {
            return line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        }
        return stderrTail.last ?? String(localized: "yt-dlp failed without saying why.")
    }
}

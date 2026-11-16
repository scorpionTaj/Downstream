import Foundation

/// Puts subtitle files inside a video that's already saved, with ffmpeg. For subtitles yt-dlp was refused
/// during the download and only got on a later try: yt-dlp itself can only embed while it downloads.
public enum SubtitleEmbedder {
    public struct Track: Equatable, Sendable {
        public var file: URL
        /// yt-dlp's language code, e.g. `ar` or `pt-BR`.
        public var language: String
    }

    static let subtitleExtensions: Set<String> = ["vtt", "srt", "ass", "ssa", "ttml", "lrc", "sbv"]

    /// The subtitle files yt-dlp wrote into `directory`, named `<anything>.<language>.<extension>`.
    public static func tracks(in directory: URL) -> [Track] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            let parts = name.split(separator: ".")
            guard parts.count >= 3, let last = parts.last, subtitleExtensions.contains(String(last)) else { return nil }
            return Track(file: directory.appendingPathComponent(name), language: String(parts[parts.count - 2]))
        }
    }

    /// The subtitle codec `container` takes, or nil when it can't hold subtitles this way.
    static func codec(forContainer container: String) -> String? {
        switch container.lowercased() {
        case "mp4", "m4v", "mov": "mov_text"
        case "mkv": "copy"
        case "webm": "webvtt"
        default: nil
        }
    }

    /// ffmpeg arguments that copy `video` into `output` with `tracks` added as its first subtitle streams.
    /// Everything already in the video — streams, cover art, chapters, tags — is kept as it is.
    static func arguments(video: URL, tracks: [Track], output: URL) -> [String]? {
        guard !tracks.isEmpty, let codec = codec(forContainer: video.pathExtension) else { return nil }
        var args = ["-y", "-loglevel", "error", "-i", video.path]
        for track in tracks { args += ["-i", track.file.path] }
        args += ["-map", "0:v?", "-map", "0:a?"]
        for index in tracks.indices { args += ["-map", "\(index + 1):0"] }
        args += ["-map", "0:s?", "-map", "0:t?", "-c", "copy", "-c:s", codec]
        for (index, track) in tracks.enumerated() {
            args += ["-metadata:s:s:\(index)", "language=\(threeLetterCode(track.language))"]
        }
        return args + [output.path]
    }

    /// `ar` → `ara`: MP4 only stores three-letter language codes. Unknown codes pass through.
    static func threeLetterCode(_ language: String) -> String {
        let primary = String(language.prefix { $0 != "-" && $0 != "_" })
        return Locale.LanguageCode(primary).identifier(.alpha3) ?? primary
    }

    /// Adds `tracks` to `video`, replacing it only once ffmpeg has written the new file. False when the
    /// container can't hold them or ffmpeg fails; the video is then untouched.
    public static func embed(_ tracks: [Track], into video: URL, ffmpeg: URL) async -> Bool {
        let output = video.deletingPathExtension().appendingPathExtension("subtitles-temp").appendingPathExtension(video.pathExtension)
        guard let arguments = arguments(video: video, tracks: tracks, output: output) else { return false }
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            _ = try await ProcessRunner.output(of: ffmpeg, arguments: arguments, timeout: .seconds(1800))
            _ = try FileManager.default.replaceItemAt(video, withItemAt: output)
            return true
        } catch {
            return false
        }
    }
}

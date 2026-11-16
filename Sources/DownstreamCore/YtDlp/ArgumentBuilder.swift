import Foundation

/// Where and with which tools a download runs. Not stored with the options: it's resolved fresh each time.
public struct DownloadContext: Sendable, Equatable {
    public var url: URL
    public var outputDirectory: URL
    public var ffmpeg: URL
    /// nil when aria2c isn't installed; aria2 options are then ignored.
    public var aria2c: URL?

    public init(url: URL, outputDirectory: URL, ffmpeg: URL, aria2c: URL? = nil) {
        self.url = url
        self.outputDirectory = outputDirectory
        self.ffmpeg = ffmpeg
        self.aria2c = aria2c
    }
}

public enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case invalidURL
    case invalidPlaylistItems(String)
    case invalidFilenameTemplate(String)
    case outOfRange(setting: String, allowed: ClosedRange<Int>)
    case unbalancedQuote

    public var description: String {
        switch self {
        case .invalidURL: String(localized: "Enter a web address that starts with http:// or https://.")
        case .invalidPlaylistItems(let items): String(localized: "“\(items)” isn't a valid item list. Use numbers, ranges and commas, like 1:5,8.")
        case .invalidFilenameTemplate(let template): String(localized: "“\(template)” must be a file name inside the download folder.")
        case .outOfRange(let setting, let allowed): String(localized: "\(setting) must be between \(allowed.lowerBound) and \(allowed.upperBound).")
        case .unbalancedQuote: String(localized: "The extra arguments have a quote that isn't closed.")
        }
    }
}

/// Turns `DownloadOptions` into yt-dlp arguments. Pure functions only, so every combination is easy to check.
public enum ArgumentBuilder {
    /// Prefixes Downstream asks yt-dlp to put on the lines it needs to parse. See `ProgressParser`.
    public static let downloadProgressPrefix = "@@P "
    public static let postprocessProgressPrefix = "@@Q "
    public static let finalFilePrefix = "@@F "
    public static let destinationPrefix = "@@D "
    public static let itemURLPrefix = "@@U "

    /// A URL Downstream will hand to yt-dlp: http or https with a host. Surrounding whitespace is ignored.
    public static func validURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Arguments for `MetadataFetcher`: one JSON document describing the URL, playlists flattened.
    /// `--no-playlist` keeps a video URL that happens to carry a `&list=` parameter a single video
    /// (a pure playlist URL is unaffected), matching what a non-playlist download would fetch.
    public static func metadataArguments(for url: URL, cookies: CookieSource?) -> [String] {
        ["--ignore-config", "--no-warnings", "--no-playlist", "--dump-single-json", "--flat-playlist"]
            + cookieArguments(cookies)
            + ["--", url.absoluteString]
    }

    public static func downloadArguments(_ options: DownloadOptions, context: DownloadContext) throws -> [String] {
        guard validURL(context.url.absoluteString) != nil else { throw ArgumentError.invalidURL }
        try validate(options)

        var args = [
            // The user's own yt-dlp config could change output in ways the parser doesn't expect.
            "--ignore-config",
            "--color", "never",
            "--newline",
            // `--print` turns on quiet mode, which would also hide progress.
            "--progress",
            "--no-mtime",
            // Without this, a fast download prints hundreds of progress lines a second, each one a UI update.
            "--progress-delta", "0.25",
            // yt-dlp retries a dropped connection or fragment 10 times, but back to back. Waiting 1 s, 2 s, 4 s…
            // (up to 20 s) between tries gives a throttling site or a flaky network time to recover.
            "--retry-sleep", "exp=1:20",
            "--retry-sleep", "fragment:exp=1:20",
            "--progress-template", "download:\(downloadProgressPrefix)%(progress)j",
            "--progress-template", "postprocess:\(postprocessProgressPrefix)%(progress)j",
            "--print", "before_dl:\(destinationPrefix)%(n_entries|)s|%(filename)s",
            // In this order: the page comes first, so it's known when the file arrives.
            "--print", "after_move:\(itemURLPrefix)%(webpage_url)s",
            "--print", "after_move:\(finalFilePrefix)%(filepath)s",
            "--ffmpeg-location", context.ffmpeg.path,
            "--paths", context.outputDirectory.path,
            "--output", options.filenameTemplate,
        ]
        if options.restrictFilenames { args.append("--restrict-filenames") }

        switch options.kind {
        case .video: args += videoArguments(options)
        case .audio: args += audioArguments(options)
        }

        if options.embedMetadata { args.append("--embed-metadata") }
        if options.embedThumbnail, supportsEmbeddedThumbnail(options) { args.append("--embed-thumbnail") }
        if options.embedChapters { args.append("--embed-chapters") }

        if let sponsorBlock = options.sponsorBlock, !sponsorBlock.categories.isEmpty {
            let flag = sponsorBlock.action == .remove ? "--sponsorblock-remove" : "--sponsorblock-mark"
            args += [flag, sponsorBlock.categories.map(\.rawValue).joined(separator: ",")]
        }

        args += cookieArguments(options.cookies)

        if let connections = options.aria2Connections, let aria2c = context.aria2c {
            args += [
                "--downloader", aria2c.path,
                // aria2c can't fetch HLS/DASH fragments well; keep yt-dlp's own downloader for those.
                "--downloader", "dash,m3u8:native",
                // No write cache: aria2c prints nothing useful through a pipe and, with the cache, doesn't touch
                // its file for minutes either. Writing as data arrives is the only sign that it's alive, which
                // `DownloadJob` watches to tell a slow transfer from a stalled one.
                "--downloader-args", "aria2c:-x \(connections) -s \(connections) -k 1M --disk-cache=0",
            ]
        }

        if let rate = options.rateLimitKiB { args += ["--limit-rate", "\(rate)K"] }

        if options.downloadPlaylist {
            args.append("--yes-playlist")
            if let items = options.playlistItems, !items.isEmpty { args += ["--playlist-items", items] }
        } else {
            args.append("--no-playlist")
        }

        args += try splitArguments(options.extraArguments)
        // Everything after `--` is a URL, even if it starts with a dash.
        args += ["--", context.url.absoluteString]
        return args
    }

    /// Arguments that fetch only the subtitles in `languages` for the video at `url`, into `directory` as
    /// `subtitles.<language>.<extension>`. For the later tries after yt-dlp was refused them (see `DownloadJob`).
    public static func subtitleArguments(_ options: DownloadOptions, url: String, languages: [String], directory: URL) -> [String] {
        var args = [
            "--ignore-config", "--color", "never", "--skip-download", "--no-playlist",
            "--paths", directory.path,
            "--output", "subtitles.%(ext)s",
            "--sub-langs", languages.joined(separator: ","),
            "--write-subs",
        ]
        if options.subtitles?.includeAutomatic == true { args.append("--write-auto-subs") }
        args += cookieArguments(options.cookies)
        return args + ["--", url]
    }

    // MARK: - Pieces

    static func videoArguments(_ options: DownloadOptions) -> [String] {
        // Format sorting rather than a strict filter: `res:1080` prefers the tallest video at or under 1080p
        // and falls back to the next size up when nothing fits, instead of failing.
        var sort: [String] = []
        if let height = options.maxHeight { sort.append("res:\(height)") }
        switch options.container {
        case .mp4: sort.append("ext:mp4:m4a")  // H.264/AAC first: plays in QuickTime without re-encoding
        case .webm: sort.append("ext:webm:webm")
        case .mkv: break
        }
        var args = ["--format", "bv*+ba/b"]
        if !sort.isEmpty { args += ["--format-sort", sort.joined(separator: ",")] }
        args += ["--merge-output-format", options.container.rawValue]
        // MP4 and MKV can hold anything yt-dlp downloads, so a single file in another container is remuxed.
        // WebM only holds VP8/VP9/AV1, so remuxing an H.264 file into it would fail; it's left as it is.
        if options.container != .webm { args += ["--remux-video", options.container.rawValue] }
        if let subtitles = options.subtitles, !subtitles.languages.isEmpty {
            args += ["--sub-langs", subtitles.languages.joined(separator: ",")]
            if subtitles.includeAutomatic { args.append("--write-auto-subs") }
            // `--embed-subs` fetches the subtitles itself and deletes the files once they're inside the video.
            // Adding `--write-subs` would leave a stray .vtt next to it, so it's only used to keep them as files.
            args.append(subtitles.embed ? "--embed-subs" : "--write-subs")
            // Subtitles are an extra: without this, a refused subtitle request (YouTube answers 429 a lot)
            // fails the whole video. With it yt-dlp warns and carries on; `DownloadJob` shows the warning.
            args.append("--ignore-errors")
        }
        return args
    }

    static func audioArguments(_ options: DownloadOptions) -> [String] {
        ["--format", "ba/b", "--extract-audio",
         "--audio-format", options.audioFormat.rawValue,
         "--audio-quality", String(options.audioQuality)]
    }

    static func cookieArguments(_ cookies: CookieSource?) -> [String] {
        switch cookies {
        case .browser(let browser): ["--cookies-from-browser", browser.rawValue]
        case .file(let path): ["--cookies", (path as NSString).expandingTildeInPath]
        case nil: []
        }
    }

    /// yt-dlp can't embed cover art in WebM or WAV.
    static func supportsEmbeddedThumbnail(_ options: DownloadOptions) -> Bool {
        switch options.kind {
        case .video: options.container != .webm
        case .audio: options.audioFormat != .wav
        }
    }

    /// What's wrong with these options, or nil if yt-dlp can be started with them. For showing next to the controls.
    public static func problem(with options: DownloadOptions) -> ArgumentError? {
        do {
            try validate(options)
            _ = try splitArguments(options.extraArguments)
            return nil
        } catch let error as ArgumentError {
            return error
        } catch {
            return nil
        }
    }

    static func validate(_ options: DownloadOptions) throws {
        if !(0...10).contains(options.audioQuality) {
            throw ArgumentError.outOfRange(setting: String(localized: "Audio quality"), allowed: 0...10)
        }
        if let connections = options.aria2Connections, !(1...16).contains(connections) {
            throw ArgumentError.outOfRange(setting: String(localized: "aria2 connections"), allowed: 1...16)
        }
        if let rate = options.rateLimitKiB, rate < 1 {
            throw ArgumentError.outOfRange(setting: String(localized: "Speed limit"), allowed: 1...Int.max)
        }
        if let height = options.maxHeight, height < 1 {
            throw ArgumentError.outOfRange(setting: String(localized: "Maximum height"), allowed: 1...Int.max)
        }
        if let items = options.playlistItems, !items.isEmpty {
            let allowed = CharacterSet(charactersIn: "0123456789:,-")
            if items.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                throw ArgumentError.invalidPlaylistItems(items)
            }
        }
        // Keep downloads inside the chosen folder: no absolute paths, home shortcuts or parent directories.
        let template = options.filenameTemplate
        if template.trimmingCharacters(in: .whitespaces).isEmpty
            || template.hasPrefix("/") || template.hasPrefix("~")
            || template.split(separator: "/").contains("..") {
            throw ArgumentError.invalidFilenameTemplate(template)
        }
    }

    /// Splits text into arguments the way a shell would (spaces separate; single quotes, double quotes and
    /// backslashes group), without running a shell.
    public static func splitArguments(_ text: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                inToken = true
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaping = true
                } else {
                    current.append(character)
                }
            } else if character == "\\" {
                escaping = true
            } else if character == "'" || character == "\"" {
                quote = character
                inToken = true
            } else if character.isWhitespace {
                if inToken { result.append(current); current = ""; inToken = false }
            } else {
                current.append(character)
                inToken = true
            }
        }
        if quote != nil || escaping { throw ArgumentError.unbalancedQuote }
        if inToken { result.append(current) }
        return result
    }
}

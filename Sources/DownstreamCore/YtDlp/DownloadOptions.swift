import Foundation

/// Everything the user can choose about a download. Codable so presets and history can store it.
public struct DownloadOptions: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case video, audio }

    public enum VideoContainer: String, Codable, Sendable, CaseIterable { case mp4, webm, mkv }

    public enum AudioFormat: String, Codable, Sendable, CaseIterable { case mp3, m4a, opus, flac, wav }

    public var kind: Kind = .video

    // Video
    public var container: VideoContainer = .mp4
    /// The tallest video wanted, e.g. 1080. nil means the best available.
    /// yt-dlp picks the largest height at or below it, or the smallest above it if nothing fits.
    public var maxHeight: Int?

    // Audio
    public var audioFormat: AudioFormat = .mp3
    /// ffmpeg's VBR scale: 0 is best, 10 is worst. Ignored by lossless formats.
    public var audioQuality: Int = 0

    public var subtitles: SubtitleOptions?
    public var embedMetadata = true
    public var embedThumbnail = true
    public var embedChapters = true
    public var sponsorBlock: SponsorBlockOptions?
    public var cookies: CookieSource?
    /// Use aria2c for plain HTTP downloads with this many connections. Ignored when aria2c isn't installed.
    public var aria2Connections: Int?
    /// Maximum speed in KiB/s. nil means unlimited.
    public var rateLimitKiB: Int?
    public var restrictFilenames = false
    /// yt-dlp output template, relative to the download folder.
    public var filenameTemplate = "%(title)s [%(id)s].%(ext)s"
    /// When the URL is (or contains) a playlist: download the playlist rather than the single video.
    public var downloadPlaylist = false
    /// yt-dlp's `--playlist-items` syntax, e.g. `1:5,8`. nil means every item.
    public var playlistItems: String?
    /// Extra yt-dlp arguments typed by the user, split like a shell would (quotes respected) but never run through one.
    public var extraArguments = ""

    public init() {}
}

public struct SubtitleOptions: Codable, Sendable, Equatable {
    /// yt-dlp language codes or patterns, e.g. `["en", "de"]` or `["en.*"]`.
    public var languages: [String]
    public var includeAutomatic: Bool
    /// Put them inside the video. Otherwise they're saved next to it.
    public var embed: Bool

    public init(languages: [String], includeAutomatic: Bool = false, embed: Bool = true) {
        self.languages = languages
        self.includeAutomatic = includeAutomatic
        self.embed = embed
    }
}

public struct SponsorBlockOptions: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Cut the segments out of the file.
        case remove
        /// Keep them, marked as chapters.
        case mark
    }

    /// SponsorBlock's segment categories. `poi_highlight` and `chapter` can't be removed, so they're left out.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case sponsor, intro, outro, selfpromo, preview, filler, interaction
        case musicOfftopic = "music_offtopic"
        case hook
    }

    public var action: Action
    public var categories: [Category]

    public init(action: Action = .remove, categories: [Category] = [.sponsor]) {
        self.action = action
        self.categories = categories
    }
}

public enum CookieSource: Codable, Sendable, Equatable {
    public enum Browser: String, Codable, Sendable, CaseIterable {
        /// Needs Full Disk Access for Downstream.
        case safari
        case chrome, firefox, brave, edge, chromium, opera, vivaldi
    }

    case browser(Browser)
    /// A Netscape-format cookies.txt file.
    case file(path: String)
}

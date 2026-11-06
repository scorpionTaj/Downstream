import Foundation

/// What `yt-dlp -J` reports about a URL: a single video, or a playlist of entries.
/// Every field is optional or defaulted and unknown keys are ignored, so new yt-dlp versions and unusual sites decode.
public struct MediaInfo: Decodable, Sendable, Equatable {
    public var id: String?
    public var title: String?
    public var webpageURL: String?
    public var uploader: String?
    public var duration: Double?
    public var thumbnail: String?
    public var isLive: Bool
    public var formats: [MediaFormat]
    /// Languages that have uploaded subtitles.
    public var subtitleLanguages: [String]
    /// Languages that only have automatically generated captions.
    public var automaticCaptionLanguages: [String]
    /// Non-nil when the URL is a playlist. Entries yt-dlp reported as unavailable are dropped.
    public var entries: [PlaylistEntry]?

    public var isPlaylist: Bool { entries != nil }

    /// Distinct video heights on offer, highest first. Drives the Quality picker.
    public var availableHeights: [Int] {
        Array(Set(formats.filter(\.hasVideo).compactMap(\.height))).sorted(by: >)
    }

    enum CodingKeys: String, CodingKey {
        case type = "_type"
        case id, title, uploader, channel, duration, thumbnail, formats, subtitles, entries
        case webpageURL = "webpage_url"
        case liveStatus = "live_status"
        case isLive = "is_live"
        case automaticCaptions = "automatic_captions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        webpageURL = try c.decodeIfPresent(String.self, forKey: .webpageURL)
        uploader = try c.decodeIfPresent(String.self, forKey: .uploader) ?? c.decodeIfPresent(String.self, forKey: .channel)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        let liveStatus = try? c.decodeIfPresent(String.self, forKey: .liveStatus)
        isLive = liveStatus == "is_live" || (try? c.decodeIfPresent(Bool.self, forKey: .isLive)) == true
        // A malformed element must not throw away every format (the quality picker would empty
        // out) — or the whole document, since the array decode was a single `try`. The wrapper
        // below absorbs the element failure, so the array decode itself always succeeds.
        formats = (try? c.decodeIfPresent([LenientMediaFormat].self, forKey: .formats))?.compactMap(\.format) ?? []
        subtitleLanguages = try Self.languages(c, .subtitles)
        automaticCaptionLanguages = try Self.languages(c, .automaticCaptions)

        let type = try c.decodeIfPresent(String.self, forKey: .type)
        if type == "playlist" || c.contains(.entries) {
            entries = try (c.decodeIfPresent([PlaylistEntry?].self, forKey: .entries) ?? []).compactMap { $0 }
        }
    }

    private static func languages(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [String] {
        guard let tracks = try? c.decodeIfPresent([String: AnyDecodable].self, forKey: key) else { return [] }
        return tracks.keys.filter { $0 != "live_chat" }.sorted()
    }
}

/// An element of `formats` that decodes to nil instead of throwing the whole array away.
/// (A failed element decode can't advance the JSON unkeyed container, so the wrapper must
/// succeed for every element — a bare `try?` loop would never reach the end.)
private struct LenientMediaFormat: Decodable {
    let format: MediaFormat?

    init(from decoder: Decoder) throws {
        format = try? MediaFormat(from: decoder)
    }
}

/// One downloadable format of a video.
public struct MediaFormat: Decodable, Sendable, Equatable, Identifiable {
    public var formatID: String
    public var ext: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    /// Exact size when known, otherwise yt-dlp's estimate.
    public var fileSize: Int64?
    public var note: String?
    public var `protocol`: String?

    public var id: String { formatID }
    public var hasVideo: Bool { Self.isCodec(videoCodec) && height != nil }
    public var hasAudio: Bool { Self.isCodec(audioCodec) }

    private static func isCodec(_ codec: String?) -> Bool { codec != nil && codec != "none" }

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext, width, height, fps, filesize
        case videoCodec = "vcodec"
        case audioCodec = "acodec"
        case filesizeApprox = "filesize_approx"
        case note = "format_note"
        case `protocol`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatID = try c.decodeIfPresent(String.self, forKey: .formatID) ?? "unknown"
        ext = try c.decodeIfPresent(String.self, forKey: .ext)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        width = Self.int(c, .width)
        height = Self.int(c, .height)
        fps = try? c.decodeIfPresent(Double.self, forKey: .fps)
        fileSize = Self.int64(c, .filesize) ?? Self.int64(c, .filesizeApprox)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol)
    }

    // yt-dlp sometimes reports whole numbers as floats (e.g. `"filesize_approx": 1234.0`).
    private static func int64(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
        if let value = try? c.decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int64(value) }
        return nil
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        int64(c, key).map { Int($0) }
    }
}

/// One item of a playlist fetched with `--flat-playlist`.
public struct PlaylistEntry: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var url: String?
    public var duration: Double?

    enum CodingKeys: String, CodingKey { case id, title, url, duration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? url ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
    }
}

/// Accepts and discards any JSON value. Used where only a dictionary's keys matter.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

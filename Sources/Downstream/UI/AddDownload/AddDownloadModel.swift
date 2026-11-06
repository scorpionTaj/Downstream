import AppKit
import DownstreamCore
import Observation

/// State of the Add Download sheet: link → video info → choices → download.
@MainActor
@Observable
final class AddDownloadModel {
    enum Phase: Equatable {
        case idle
        case fetching
        case ready(MediaInfo)
        case failed(String)
    }

    /// Offered when a playlist doesn't say which heights exist.
    static let standardHeights = [2160, 1440, 1080, 720, 480, 360]

    var isPresented = false
    var urlText = ""
    private(set) var phase: Phase = .idle

    var kind: DownloadOptions.Kind = .video
    /// nil means best available.
    var maxHeight: Int?
    var container: DownloadOptions.VideoContainer = .mp4
    var audioFormat: DownloadOptions.AudioFormat = .mp3
    var subtitlesEnabled = false
    var subtitleLanguage = ""
    var embedThumbnailAndMetadata = true
    var folder: URL = AppSettings.downloadFolder

    private var fetchTask: Task<Void, Never>?

    /// Opens the sheet, starting from the link on the clipboard if there is one.
    func present(ytDlp: URL?) {
        fetchTask?.cancel()
        phase = .idle
        urlText = ""
        folder = AppSettings.downloadFolder
        isPresented = true
        if let text = NSPasteboard.general.string(forType: .string), let url = ArgumentBuilder.validURL(text) {
            urlText = url.absoluteString
            if let ytDlp { fetch(ytDlp: ytDlp) }
        }
    }

    func dismiss() {
        fetchTask?.cancel()
        isPresented = false
    }

    /// Typing a new link discards info fetched for the old one.
    func urlTextChanged() {
        switch phase {
        case .ready, .failed: phase = .idle
        case .idle, .fetching: break
        }
    }

    func fetch(ytDlp: URL) {
        guard let url = ArgumentBuilder.validURL(urlText) else {
            phase = .failed(ArgumentError.invalidURL.description)
            return
        }
        fetchTask?.cancel()
        phase = .fetching
        fetchTask = Task {
            do {
                let info = try await MetadataFetcher(ytDlp: ytDlp).fetch(url)
                guard !Task.isCancelled else { return }
                applyDefaults(for: info)
                phase = .ready(info)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.message(for: error))
            }
        }
    }

    var info: MediaInfo? {
        if case .ready(let info) = phase { info } else { nil }
    }

    var heightChoices: [Int] {
        guard let info, !info.availableHeights.isEmpty else { return Self.standardHeights }
        return info.availableHeights
    }

    /// Uploaded subtitles first, then automatic captions.
    var subtitleChoices: [String] {
        guard let info else { return [] }
        let uploaded = info.subtitleLanguages
        return uploaded + info.automaticCaptionLanguages.filter { !uploaded.contains($0) }
    }

    func isAutomatic(_ language: String) -> Bool {
        info.map { !$0.subtitleLanguages.contains(language) } ?? false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func makeOptions() -> DownloadOptions {
        var options = DownloadOptions()
        options.kind = kind
        options.maxHeight = maxHeight
        options.container = container
        options.audioFormat = audioFormat
        options.embedThumbnail = embedThumbnailAndMetadata
        options.embedMetadata = embedThumbnailAndMetadata
        options.downloadPlaylist = info?.isPlaylist ?? false
        if kind == .video, subtitlesEnabled, !subtitleLanguage.isEmpty {
            options.subtitles = SubtitleOptions(languages: [subtitleLanguage], includeAutomatic: isAutomatic(subtitleLanguage), embed: true)
        }
        return options
    }

    func start(in manager: DownloadManager, tools: DownloadTools) {
        guard let info, let url = ArgumentBuilder.validURL(urlText) else { return }
        AppSettings.downloadFolder = folder
        manager.add(url: url, options: makeOptions(), title: info.title,
                    thumbnailURL: info.thumbnail.flatMap(URL.init(string:)),
                    outputDirectory: folder, tools: tools)
        isPresented = false
    }

    private func applyDefaults(for info: MediaInfo) {
        if let height = maxHeight, !heightChoices(for: info).contains(height) { maxHeight = nil }
        let languages = info.subtitleLanguages + info.automaticCaptionLanguages
        let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        subtitleLanguage = preferred.first(where: languages.contains) ?? (languages.contains("en") ? "en" : languages.first ?? "")
    }

    private func heightChoices(for info: MediaInfo) -> [Int] {
        info.availableHeights.isEmpty ? Self.standardHeights : info.availableHeights
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let error as MetadataError: error.description
        case ProcessError.timedOut: "The site took too long to answer. Try again."
        default: "Couldn't read this link: \(error)"
        }
    }
}

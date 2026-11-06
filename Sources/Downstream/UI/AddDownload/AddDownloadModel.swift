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

    /// The preset the choices came from, or nil for Downstream's defaults.
    private(set) var presetID: UUID?
    /// The preset's full options. Settings the sheet doesn't show (SponsorBlock, cookies…) come from here.
    private var baseOptions = DownloadOptions()
    var isNamingPreset = false
    var newPresetName = ""

    private let library: Library
    private var fetchTask: Task<Void, Never>?

    init(library: Library) {
        self.library = library
    }

    /// Opens the sheet, starting from the link on the clipboard if there is one.
    func present(ytDlp: URL?) {
        fetchTask?.cancel()
        phase = .idle
        urlText = ""
        folder = AppSettings.downloadFolder
        applyPreset(id: AppSettings.defaultPresetID)
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

    /// The heights on offer, plus the preset's own if this video doesn't list it
    /// (yt-dlp then picks the nearest size, so it still works).
    var heightChoices: [Int] {
        let offered = info.map(heightChoices(for:)) ?? Self.standardHeights
        guard let maxHeight, !offered.contains(maxHeight) else { return offered }
        return (offered + [maxHeight]).sorted(by: >)
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
        var options = baseOptions
        options.kind = kind
        options.maxHeight = maxHeight
        options.container = container
        options.audioFormat = audioFormat
        options.embedThumbnail = embedThumbnailAndMetadata
        options.embedMetadata = embedThumbnailAndMetadata
        options.downloadPlaylist = info?.isPlaylist ?? false
        options.subtitles = nil
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

    // MARK: Presets

    var presets: [Preset] { library.presets }

    var isDefaultPreset: Bool { presetID != nil && presetID == AppSettings.defaultPresetID }

    /// The choices differ from the selected preset's.
    var isPresetEdited: Bool {
        guard let preset = library.preset(id: presetID) else { return false }
        return Self.comparable(makeOptions()) != Self.comparable(preset.options)
    }

    /// Fills the sheet from a preset, or from Downstream's defaults for nil.
    func applyPreset(id: UUID?) {
        let preset = library.preset(id: id)
        presetID = preset?.id
        baseOptions = preset?.options ?? DownloadOptions()
        kind = baseOptions.kind
        maxHeight = baseOptions.maxHeight
        container = baseOptions.container
        audioFormat = baseOptions.audioFormat
        embedThumbnailAndMetadata = baseOptions.embedThumbnail && baseOptions.embedMetadata
        subtitlesEnabled = baseOptions.subtitles != nil
        if let language = baseOptions.subtitles?.languages.first { subtitleLanguage = language }
        if let info { chooseSubtitleLanguage(for: info) }
    }

    func beginSavingPreset() {
        newPresetName = library.preset(id: presetID)?.name ?? ""
        isNamingPreset = true
    }

    /// Saves the current choices under `newPresetName`, replacing a preset with the same name.
    func saveNamedPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = library.savePreset(named: name, options: Self.comparable(makeOptions()))
        presetID = preset.id
        baseOptions = preset.options
    }

    func deleteSelectedPreset() {
        guard let preset = library.preset(id: presetID) else { return }
        if AppSettings.defaultPresetID == preset.id { AppSettings.defaultPresetID = nil }
        library.deletePreset(preset)
        presetID = nil
        baseOptions = DownloadOptions()
    }

    func setDefaultPreset(_ isDefault: Bool) {
        AppSettings.defaultPresetID = isDefault ? presetID : nil
    }

    /// Presets don't remember whether one particular link was a playlist.
    private static func comparable(_ options: DownloadOptions) -> DownloadOptions {
        var options = options
        options.downloadPlaylist = false
        options.playlistItems = nil
        return options
    }

    private func applyDefaults(for info: MediaInfo) {
        chooseSubtitleLanguage(for: info)
    }

    /// Keeps the preset's language if this video has it, else picks the system language, then English.
    private func chooseSubtitleLanguage(for info: MediaInfo) {
        let languages = info.subtitleLanguages + info.automaticCaptionLanguages
        if languages.contains(subtitleLanguage) { return }
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

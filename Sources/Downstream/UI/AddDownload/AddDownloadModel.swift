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
    /// The full options: the preset's (or the defaults from Settings), with "More options" edited in place.
    /// The simple choices above are kept in their own properties and laid over these by `makeOptions()`.
    var options = AppSettings.defaultOptions
    /// For a playlist, the 1-based numbers of the items to download.
    var selectedItems: Set<Int> = []
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
                selectedItems = Set(1...max(1, info.entries?.count ?? 1))
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
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func makeOptions() -> DownloadOptions {
        var options = options
        options.kind = kind
        options.maxHeight = maxHeight
        options.container = container
        options.audioFormat = audioFormat
        options.embedThumbnail = embedThumbnailAndMetadata
        options.embedMetadata = embedThumbnailAndMetadata
        options.downloadPlaylist = info?.isPlaylist ?? false
        options.playlistItems = options.downloadPlaylist
            ? PlaylistSelection.spec(selected: selectedItems, count: info?.entries?.count ?? 0)
            : nil
        options.subtitles = nil
        if kind == .video, subtitlesEnabled, !subtitleLanguage.isEmpty {
            options.subtitles = SubtitleOptions(languages: [subtitleLanguage], includeAutomatic: isAutomatic(subtitleLanguage), embed: true)
        }
        return options
    }

    /// Why the Download button is disabled, or nil when it can be pressed.
    var downloadBlocker: String? {
        guard let info else { return "" }
        if info.isPlaylist && selectedItems.isEmpty { return String(localized: "Select at least one video.") }
        return ArgumentBuilder.problem(with: makeOptions())?.description
    }

    func start(in manager: DownloadManager, tools: DownloadTools) {
        guard let info, let url = ArgumentBuilder.validURL(urlText), downloadBlocker == nil else { return }
        AppSettings.downloadFolder = folder
        manager.add(url: url, options: makeOptions(), title: info.title,
                    thumbnailURL: info.thumbnail.flatMap(URL.init(string:)),
                    outputDirectory: folder, tools: tools)
        isPresented = false
    }

    // MARK: Quick download (menu bar)

    /// The link on the clipboard, if it's one Downstream can download.
    static var clipboardLink: URL? {
        NSPasteboard.general.string(forType: .string).flatMap(ArgumentBuilder.validURL)
    }

    /// Downloads the clipboard's link straight away with the default preset (or the default settings),
    /// into the usual folder. The title and thumbnail fill in once yt-dlp has looked the link up.
    /// Returns why it couldn't, or nil when the download was added.
    @discardableResult
    func downloadClipboardLink(in manager: DownloadManager, tools: DownloadTools) -> String? {
        guard let url = Self.clipboardLink else { return String(localized: "Copy a link first.") }
        let options = library.preset(id: AppSettings.defaultPresetID)?.options ?? AppSettings.defaultOptions
        if let problem = ArgumentBuilder.problem(with: options) { return problem.description }
        let job = manager.add(url: url, options: options, title: nil, thumbnailURL: nil,
                              outputDirectory: AppSettings.downloadFolder, tools: tools)
        Task {
            guard let info = try? await MetadataFetcher(ytDlp: tools.ytDlp).fetch(url, cookies: options.cookies) else { return }
            if let title = info.title { job.title = title }
            job.thumbnailURL = info.thumbnail.flatMap(URL.init(string:))
        }
        return nil
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
        options = preset?.options ?? AppSettings.defaultOptions
        kind = options.kind
        maxHeight = options.maxHeight
        container = options.container
        audioFormat = options.audioFormat
        embedThumbnailAndMetadata = options.embedThumbnail && options.embedMetadata
        subtitlesEnabled = options.subtitles != nil
        if let language = options.subtitles?.languages.first { subtitleLanguage = language }
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
        options = preset.options
    }

    func deleteSelectedPreset() {
        guard let preset = library.preset(id: presetID) else { return }
        if AppSettings.defaultPresetID == preset.id { AppSettings.defaultPresetID = nil }
        library.deletePreset(preset)
        presetID = nil
        options = AppSettings.defaultOptions
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
        case ProcessError.timedOut: String(localized: "The site took too long to answer. Try again.")
        default: String(localized: "Couldn't read this link: \(error.localizedDescription)")
        }
    }
}

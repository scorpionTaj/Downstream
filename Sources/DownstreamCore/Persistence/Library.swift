import Foundation
import Observation

/// A finished download (completed or failed), kept after it leaves the download list.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var thumbnailURL: URL?
    /// The saved file. nil for a failed download.
    public var file: URL?
    public var fileSize: Int64?
    /// Why it failed, or nil if it completed. (Older history files don't have this field: they decode as completed.)
    public var failure: String?
    /// The subtitles that were asked for couldn't be fetched. (Older history files don't have this field.)
    public var subtitlesMissing: Bool?
    public var options: DownloadOptions
    public var completedAt: Date

    public var isFailed: Bool { failure != nil }

    public init(id: UUID = UUID(), url: URL, title: String, thumbnailURL: URL?, file: URL?, fileSize: Int64?,
                options: DownloadOptions, failure: String? = nil, subtitlesMissing: Bool? = nil, completedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.file = file
        self.fileSize = fileSize
        self.options = options
        self.failure = failure
        self.subtitlesMissing = subtitlesMissing
        self.completedAt = completedAt
    }
}

/// A named set of download options.
public struct Preset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var options: DownloadOptions

    public init(id: UUID = UUID(), name: String, options: DownloadOptions) {
        self.id = id
        self.name = name
        self.options = options
    }
}

/// A download that hadn't finished, or had failed, when the app quit. Restored on next launch.
public struct PendingDownload: Codable, Sendable, Equatable {
    public var url: URL
    public var title: String
    public var thumbnailURL: URL?
    public var options: DownloadOptions
    public var outputDirectory: URL
    public var createdAt: Date
    /// When the current attempt started and which files it wrote, so cancelling after a relaunch still cleans up.
    public var startedAt: Date?
    public var writtenFiles: [String]
    public var lastProgress: SavedProgress?
    /// Set for a download that failed: it comes back failed, with its log, instead of paused.
    /// (Older files don't have these fields.)
    public var failure: String? = nil
    public var log: [String]? = nil
    /// Why Downstream paused it, when it did.
    public var pauseReason: PauseReason? = nil

    public struct SavedProgress: Codable, Sendable, Equatable {
        public var downloadedBytes: Int64
        public var totalBytes: Int64?
    }
}

/// History, presets and unfinished downloads, each in its own JSON file.
@MainActor
@Observable
public final class Library {
    /// Oldest entries are dropped beyond this.
    public static let historyLimit = 2000

    /// Newest first.
    public private(set) var history: [HistoryEntry]
    /// In the order the user created them.
    public private(set) var presets: [Preset]
    /// Set when a save fails, for the UI to report. Cleared by the next successful save.
    public private(set) var saveError: String?

    private let historyStore: JSONFileStore<[HistoryEntry]>
    private let presetStore: JSONFileStore<[Preset]>
    private let pendingStore: JSONFileStore<[PendingDownload]>

    public init(directory: URL) {
        historyStore = JSONFileStore(directory: directory, name: "history")
        presetStore = JSONFileStore(directory: directory, name: "presets")
        pendingStore = JSONFileStore(directory: directory, name: "pending")
        history = historyStore.load() ?? []
        presets = presetStore.load() ?? []
    }

    /// `~/Library/Application Support/Downstream`.
    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downstream", isDirectory: true)
    }

    // MARK: History

    /// Adds a completed or failed job. Paused, cancelled and running jobs aren't recorded.
    public func record(_ job: DownloadJob) {
        if case .failed(let message) = job.state {
            history.insert(HistoryEntry(url: job.url, title: job.title, thumbnailURL: job.thumbnailURL, file: nil,
                                        fileSize: nil, options: job.options, failure: message), at: 0)
            trimAndSaveHistory()
            return
        }
        guard case .completed(let file) = job.state else { return }
        // A playlist saves several files; each becomes its own entry. Files recorded by an earlier run of the
        // same job (before its missing items were retried) aren't listed again.
        let isPlaylist = job.savedFiles.count > 1
        let entries = job.unrecordedFiles.reversed().map { saved in
            HistoryEntry(url: job.url, title: isPlaylist ? saved.deletingPathExtension().lastPathComponent : job.title,
                         thumbnailURL: isPlaylist ? nil : job.thumbnailURL, file: saved,
                         fileSize: saved == file ? job.savedFileSize : nil, options: job.options,
                         subtitlesMissing: job.owesSubtitles(for: saved) ? true : nil)
        }
        history.insert(contentsOf: entries, at: 0)
        if job.failedItems > 0 {
            // The items that didn't make it, so the playlist shows under Failed and can be tried again.
            let total = job.playlistTotal ?? job.savedFiles.count + job.failedItems
            history.insert(HistoryEntry(url: job.url, title: job.title, thumbnailURL: job.thumbnailURL, file: nil, fileSize: nil,
                                        options: job.options,
                                        failure: String(localized: "\(total - job.savedFiles.count) of \(total) items couldn't be downloaded.")), at: 0)
        }
        trimAndSaveHistory()
    }

    /// Updates the "no subtitles" note of a job's files after its later tries for them.
    public func updateSubtitles(for job: DownloadJob) {
        var changed = false
        for index in history.indices {
            guard let file = history[index].file, job.savedFiles.contains(file) else { continue }
            let missing: Bool? = job.owesSubtitles(for: file) ? true : nil
            if history[index].subtitlesMissing != missing {
                history[index].subtitlesMissing = missing
                changed = true
            }
        }
        if changed { save(history, to: historyStore) }
    }

    private func trimAndSaveHistory() {
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        save(history, to: historyStore)
    }

    public func removeHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        save(history, to: historyStore)
    }

    public func clearHistory() {
        history = []
        save(history, to: historyStore)
    }

    // MARK: Presets

    /// Saves options under a name. An existing preset with the same name (ignoring case) is replaced.
    @discardableResult
    public func savePreset(named name: String, options: DownloadOptions) -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            presets[index].options = options
            save(presets, to: presetStore)
            return presets[index]
        }
        let preset = Preset(name: trimmed, options: options)
        presets.append(preset)
        save(presets, to: presetStore)
        return preset
    }

    public func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        save(presets, to: presetStore)
    }

    public func preset(id: UUID?) -> Preset? {
        id.flatMap { id in presets.first { $0.id == id } }
    }

    // MARK: Unfinished downloads

    public func savePending(_ downloads: [PendingDownload]) {
        save(downloads, to: pendingStore)
    }

    /// The downloads saved at the last quit. The file is read once; later saves replace it.
    public func loadPending() -> [PendingDownload] {
        pendingStore.load() ?? []
    }

    private func save<Value: Codable>(_ value: Value, to store: JSONFileStore<Value>) {
        do {
            try store.save(value)
            saveError = nil
        } catch {
            saveError = "Couldn't save \(store.url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

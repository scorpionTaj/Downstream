import DownstreamCore
import Foundation
import Observation

/// The Settings window's values. Each change is saved right away (see `AppSettings`) and applied where it matters.
@MainActor
@Observable
final class SettingsModel {
    var downloadFolder: URL { didSet { AppSettings.downloadFolder = downloadFolder } }

    var maxConcurrent: Int {
        didSet {
            AppSettings.setMaxConcurrentDownloads(maxConcurrent)
            onMaxConcurrentChanged?(maxConcurrent)
        }
    }

    var notificationsEnabled: Bool { didSet { AppSettings.setNotificationsEnabled(notificationsEnabled) } }

    /// What new downloads start from when no preset is chosen.
    var defaultOptions: DownloadOptions { didSet { AppSettings.defaultOptions = defaultOptions } }

    var toolPaths: [Tool: String] { didSet { AppSettings.toolOverrides = toolPaths } }

    var onMaxConcurrentChanged: ((Int) -> Void)?

    init() {
        downloadFolder = AppSettings.downloadFolder
        maxConcurrent = AppSettings.maxConcurrentDownloads
        notificationsEnabled = AppSettings.notificationsEnabled
        defaultOptions = AppSettings.defaultOptions
        toolPaths = AppSettings.toolOverrides
    }

    /// Picks up values changed elsewhere (the Add Download sheet remembers the last folder).
    func reload() {
        if downloadFolder != AppSettings.downloadFolder { downloadFolder = AppSettings.downloadFolder }
    }
}

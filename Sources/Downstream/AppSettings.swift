import DownstreamCore
import Foundation

/// Settings stored in UserDefaults. The Settings window (milestone 6) edits these.
enum AppSettings {
    private static let downloadFolderKey = "downloadFolder"
    private static let maxConcurrentKey = "maxConcurrentDownloads"
    private static let notificationsKey = "notificationsEnabled"

    /// How many downloads run at once. Default 3.
    static var maxConcurrentDownloads: Int {
        let stored = UserDefaults.standard.integer(forKey: maxConcurrentKey)
        return stored > 0 ? stored : DownloadManager.defaultMaxConcurrent
    }

    /// Notify when a download finishes while the app is in the background. Default on.
    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsKey) as? Bool ?? true
    }

    static var defaultDownloadFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Downstream", isDirectory: true)
    }

    /// Where history, presets and unfinished downloads are saved. Overridable for testing:
    ///   open build/Downstream.app --args -DownstreamDataDirectory /some/folder
    static var dataDirectory: URL {
        UserDefaults.standard.string(forKey: "DownstreamDataDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Library.defaultDirectory
    }

    /// The options new downloads start from when no preset is chosen. Edited in Settings › Download defaults.
    static var defaultOptions: DownloadOptions {
        get {
            UserDefaults.standard.data(forKey: "defaultDownloadOptions")
                .flatMap { try? JSONDecoder().decode(DownloadOptions.self, from: $0) } ?? DownloadOptions()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "defaultDownloadOptions") }
    }

    /// Paths the user chose for each tool, used before Homebrew's directories.
    static var toolOverrides: [Tool: String] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: "toolPaths") as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Tool(rawValue: key).map { ($0, value) } })
        }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(stored, forKey: "toolPaths")
        }
    }

    static func setMaxConcurrentDownloads(_ value: Int) {
        UserDefaults.standard.set(max(1, value), forKey: maxConcurrentKey)
    }

    static func setNotificationsEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: notificationsKey)
    }

    /// The preset applied when the Add Download sheet opens. nil means Downstream's defaults.
    static var defaultPresetID: UUID? {
        get { UserDefaults.standard.string(forKey: "defaultPresetID").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "defaultPresetID") }
    }

    /// Where new downloads go. The app isn't sandboxed, so a plain path is enough.
    static var downloadFolder: URL {
        get {
            UserDefaults.standard.string(forKey: downloadFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? defaultDownloadFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: downloadFolderKey) }
    }
}

extension URL {
    /// The path with the home folder shown as ~.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

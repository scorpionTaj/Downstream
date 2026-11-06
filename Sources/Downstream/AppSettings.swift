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

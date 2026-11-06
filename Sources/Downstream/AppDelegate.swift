import AppKit
import DownstreamCore
import UserNotifications

/// Owns the app-wide models and handles quitting and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tools = ToolSetupModel()
    let downloads = DownloadManager(maxConcurrent: AppSettings.maxConcurrentDownloads)
    let addDownload = AddDownloadModel()
    let window = MainWindowModel()

    override init() {
        super.init()
        downloads.onJobFinished = { [weak self] job in self?.notify(about: job) }
    }

    /// Unfinished downloads would be lost silently, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = downloads.unfinishedCount
        guard count > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit with a download unfinished?" : "Quit with \(count) downloads unfinished?"
        alert.informativeText = "Running and queued downloads will stop. Partly downloaded files stay in the download folder."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        downloads.pauseAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // yt-dlp runs as a separate process and would otherwise keep going after the app quits.
        downloads.pauseAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }

    /// Posts "Download finished/failed", but only while the app is in the background: in front, the list already shows it.
    private func notify(about job: DownloadJob) {
        guard AppSettings.notificationsEnabled, !NSApp.isActive,
              Bundle.main.bundleIdentifier != nil  // a bare `swift run` executable can't post notifications
        else { return }

        let content = UNMutableNotificationContent()
        switch job.state {
        case .completed:
            content.title = "Download finished"
            content.body = job.title
        case .failed(let message):
            content.title = "Download failed"
            content.body = "\(job.title)\n\(message)"
        default:
            return
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)

        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}

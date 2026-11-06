import AppKit
import DownstreamCore
import UserNotifications

/// Owns the app-wide models and handles launching, quitting and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tools = ToolSetupModel()
    let downloads = DownloadManager(maxConcurrent: AppSettings.maxConcurrentDownloads)
    let library = Library(directory: AppSettings.dataDirectory)
    let addDownload: AddDownloadModel
    let window = MainWindowModel()

    /// Unfinished downloads from the last session are only written back once they've been restored;
    /// until then the saved file is left alone, so quitting before the tools are found loses nothing.
    private var restoredPending = false

    override init() {
        addDownload = AddDownloadModel(library: library)
        super.init()
        downloads.onJobFinished = { [weak self] job in
            guard let self else { return }
            if case .completed = job.state { library.record(job) }
            notify(about: job)
        }
        downloads.onQueueChanged = { [weak self] in self?.savePending() }
        tools.onRefresh = { [weak self] in self?.restorePendingOnce() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await tools.refresh() }
    }

    /// Unfinished downloads would stop, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = downloads.runningCount + downloads.queuedCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = running == 1 ? "Quit with a download in progress?" : "Quit with \(running) downloads in progress?"
        alert.informativeText = "They'll be paused and listed again the next time you open Downstream, ready to resume."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save before stopping: yt-dlp runs as a separate process and would otherwise keep going after the app quits.
        savePending()
        downloads.pauseAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }

    private func restorePendingOnce() {
        guard !restoredPending, let downloadTools = tools.downloadTools else { return }
        restoredPending = true
        downloads.restore(library.loadPending(), tools: downloadTools)
    }

    private func savePending() {
        guard restoredPending else { return }
        library.savePending(downloads.pendingDownloads)
    }

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

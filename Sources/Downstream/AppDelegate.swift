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
    let settings = SettingsModel()
    let updates = AppUpdateModel()

    static let links = (
        repository: URL(string: "https://github.com/\(AppUpdater.repository)")!,
        releases: URL(string: "https://github.com/\(AppUpdater.repository)/releases")!,
        issues: URL(string: "https://github.com/\(AppUpdater.repository)/issues/new")!,
        supportedSites: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!
    )

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
        tools.downloads = downloads
        tools.onRefresh = { [weak self] in
            self?.restorePendingOnce()
            self?.tools.updateYtDlpIfDue()
            self?.updates.checkIfDue()
        }
        settings.onMaxConcurrentChanged = { [weak self] in self?.downloads.maxConcurrent = $0 }
        settings.onDockIconChanged = { hidden in Self.applyDockIcon(hidden: hidden) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Downstream keeps working with its window closed (downloads, menu bar), so it opts out of
        // automatic termination. Sudden termination (at logout) would skip saving unfinished downloads.
        // Note: "quit when the last window closes" utilities (e.g. Vorssaint) still quit it; that's their setting.
        ProcessInfo.processInfo.disableAutomaticTermination("Downstream keeps running in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        Self.applyDockIcon(hidden: AppSettings.hideDockIcon)
        showNoticeOnFirstLaunch()
        Task { await tools.refresh() }
    }

    /// Shown once: Downstream is a neutral tool, and what gets downloaded with it is up to the user.
    private func showNoticeOnFirstLaunch() {
        let key = "acceptedNotice"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Before you start")
        alert.informativeText = String(localized: "Downstream downloads video and audio from websites using yt-dlp. Only download content you own or have permission to download, and follow each site's terms.")
        alert.addButton(withTitle: String(localized: "I understand"))
        alert.addButton(withTitle: String(localized: "Quit"))
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Downloads keep running with the window closed; the menu bar or the Dock brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `.accessory` removes the Dock icon and the app menu; `.regular` is a normal app.
    /// A bare `swift run` executable needs `.regular` to show a window at all.
    static func applyDockIcon(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden { NSApp.activate() }
    }

    /// Unfinished downloads would stop, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = downloads.runningCount + downloads.queuedCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = running == 1 ? String(localized: "Quit with a download in progress?") : String(localized: "Quit with \(running) downloads in progress?")
        alert.informativeText = String(localized: "They'll be paused and listed again the next time you open Downstream, ready to resume.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save before stopping: yt-dlp runs as a separate process and would otherwise keep going after the app quits.
        savePending()
        downloads.pauseAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }

    // MARK: Menu actions

    /// Downloads the copied link with the default settings; reports a problem in an alert.
    func pasteAndDownload() {
        guard let downloadTools = tools.downloadTools else { return }
        if let problem = addDownload.downloadClipboardLink(in: downloads, tools: downloadTools) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't start the download")
            alert.informativeText = problem
            alert.runModal()
        } else {
            show(.all)
        }
    }

    func openDownloadsFolder() {
        let folder = AppSettings.downloadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Selects a sidebar section and brings the window forward.
    func show(_ filter: DownloadFilter) {
        window.filter = filter
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }

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
            content.title = String(localized: "Download finished")
            content.body = job.title
        case .failed(let message):
            content.title = String(localized: "Download failed")
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

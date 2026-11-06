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

    /// The running delegate, for the few places outside SwiftUI's environment that need it.
    private(set) static weak var shared: AppDelegate?

    /// Set by an explicit "quit now" (menu bar Quit, relaunch after an update): skips the questions.
    private var quittingWithoutAsking = false

    /// Unfinished downloads from the last session are only written back once they've been restored;
    /// until then the saved file is left alone, so quitting before the tools are found loses nothing.
    private var restoredPending = false

    override init() {
        addDownload = AddDownloadModel(library: library)
        super.init()
        Self.shared = self
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
        AppSettings.applyAppearance()
        showWelcomeOrWhatsNew()
        Task { await tools.refresh() }
    }

    /// First launch: the welcome guide (which also carries the "download only what you may" notice).
    /// After an update: what's new in this version.
    private func showWelcomeOrWhatsNew() {
        let current = updates.currentVersion
        let lastSeen = UserDefaults.standard.string(forKey: "lastSeenVersion")
        UserDefaults.standard.set(current, forKey: "lastSeenVersion")
        if !UserDefaults.standard.bool(forKey: "acceptedNotice") {
            window.showWelcome = true
        } else if let lastSeen, let old = AppVersion(lastSeen), let new = AppVersion(current), new > old,
                  ChangelogView.changelog.release(current) != nil {
            window.whatsNew = VersionItem(version: current)
        }
    }

    func showWelcome() {
        window.welcomePage = 0
        window.showWelcome = true
        show(window.filter)
    }

    /// Downloads keep running with the window closed; the menu bar or the Dock brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `.accessory` removes the Dock icon and the app menu; `.regular` is a normal app.
    /// A bare `swift run` executable needs `.regular` to show a window at all.
    static func applyDockIcon(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden { NSApp.activate() }
    }

    /// ⌘Q: quit, or keep running in the menu bar, as chosen in Settings (or asked, with "Remember my choice").
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quittingWithoutAsking { return .terminateNow }
        let running = downloads.runningCount + downloads.queuedCount

        switch AppSettings.quitBehavior {
        case .keepRunning:
            keepRunningInBackground()
            return .terminateCancel
        case .quit:
            return confirmQuitWithDownloads(running) ? .terminateNow : .terminateCancel
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Downstream or keep it running?")
        var info = String(localized: "Kept running, Downstream stays in the menu bar and finishes your downloads.")
        if running > 0 {
            info += "\n\n" + String(localized: "If you quit, \(running) downloads are paused and come back the next time you open Downstream.")
        }
        alert.informativeText = info
        alert.addButton(withTitle: AppSettings.showInMenuBar ? String(localized: "Keep in Menu Bar") : String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Remember my choice (change it in Settings › General)")
        NSApp.activate()
        let answer = alert.runModal()
        let remember = alert.suppressionButton?.state == .on
        switch answer {
        case .alertFirstButtonReturn:
            if remember { AppSettings.quitBehavior = .keepRunning }
            keepRunningInBackground()
            return .terminateCancel
        case .alertSecondButtonReturn:
            if remember { AppSettings.quitBehavior = .quit }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Asks before quitting with downloads in progress. True to go ahead.
    private func confirmQuitWithDownloads(_ running: Int) -> Bool {
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = running == 1 ? String(localized: "Quit with a download in progress?") : String(localized: "Quit with \(running) downloads in progress?")
        alert.informativeText = String(localized: "They'll be paused and listed again the next time you open Downstream, ready to resume.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Closes the windows and keeps working: in the menu bar if it's shown (Dock icon hidden until a window
    /// opens again), otherwise hidden with its Dock icon.
    func keepRunningInBackground() {
        for window in NSApp.windows where window.isVisible && window.identifier?.rawValue.hasPrefix("main") == true {
            window.close()
        }
        if AppSettings.showInMenuBar {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.hide(nil)
        }
    }

    /// Quits and opens Downstream again (after an update, or to switch language).
    func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                                Bundle.main.bundleURL.path]
        try? relauncher.run()
        quitNow()
    }

    /// Quits right away, without the quit question (downloads are still paused and saved).
    func quitNow() {
        quittingWithoutAsking = true
        // macOS refuses to quit while a sheet is open. Stop SwiftUI from showing any (another may be queued
        // behind the one closing), end those already attached, and do it again right before quitting.
        let closeSheets = { [self] in
            window.showWelcome = false
            window.whatsNew = nil
            window.logJob = nil
            updates.isPresented = false
            addDownload.isPresented = false
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        }
        closeSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            closeSheets()
            NSApp.terminate(nil)
        }
    }

    /// After running in the background, opening a window brings the Dock icon back (unless it's set to stay hidden).
    func restoreDockIconIfNeeded() {
        if !AppSettings.hideDockIcon, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
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
        restoreDockIconIfNeeded()
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

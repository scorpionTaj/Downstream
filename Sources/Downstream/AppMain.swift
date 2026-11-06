import AppKit
import DownstreamCore
import SwiftUI

@main
struct DownstreamApp: App {
    // `@State` needs a macro plugin that isn't in the Command Line Tools, so the app-wide
    // models live on the app delegate, which SwiftUI creates once.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    @AppStorage(AppSettings.showMenuBarKey) private var showInMenuBar = true

    var body: some Scene {
        // A `WindowGroup`, so the window can be closed and opened again from the menu bar or the Dock;
        // "Open Downstream" reuses the open window rather than adding another.
        WindowGroup("Downstream", id: "main") {
            RootView()
                .environment(app.tools)
                .environment(app.downloads)
                .environment(app.addDownload)
                .environment(app.window)
                .environment(app.library)
                .environment(app.settings)
                .environment(app.updates)
                .tint(Theme.pink)
                .environment(\.layoutDirection, Theme.layoutDirection)
        }
        .windowResizability(.contentMinSize)
        // Always open the window at launch, even if it was closed when the app last quit.
        .restorationBehavior(.disabled)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app.settings)
                .environment(app.tools)
                .environment(app.updates)
                .environment(app.window)
                .tint(Theme.pink)
                .environment(\.layoutDirection, Theme.layoutDirection)
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarView()
                .environment(app.tools)
                .environment(app.downloads)
                .environment(app.addDownload)
                .environment(app.window)
                .environment(app.library)
                .environment(app.updates)
                .tint(Theme.pink)
                .environment(\.layoutDirection, Theme.layoutDirection)
        } label: {
            Image(systemName: app.downloads.runningCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .accessibilityLabel("Downstream")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The app's menus: everything in the window is also reachable from the keyboard.
struct AppCommands: Commands {
    let app: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { app.updates.checkNow() }
        }

        CommandGroup(replacing: .newItem) {
            Button("Add Download…") { app.addDownload.present(ytDlp: app.tools.downloadTools?.ytDlp) }
                .keyboardShortcut("n")
                .disabled(app.tools.downloadTools == nil)
            Button("Paste Link and Download") { app.pasteAndDownload() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(app.tools.downloadTools == nil)
            Divider()
            Button("Open Downloads Folder") { app.openDownloadsFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Downloads") {
            Button("Pause All") { app.downloads.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(app.downloads.runningCount + app.downloads.queuedCount == 0)
            Button("Resume All") { app.downloads.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(app.downloads.pausedCount == 0)
            Button("Retry Failed") { app.downloads.retryFailed() }
                .disabled(app.downloads.failedCount == 0)
            Divider()
            Button("Cancel All") { app.downloads.cancelAll() }
                .disabled(app.downloads.unfinishedCount == 0)
            Button("Clear Finished") { app.downloads.removeFinished() }
                .disabled(!app.downloads.jobs.contains(where: \.isFinished))
            Divider()
            Button(app.tools.isUpdating ? "Updating yt-dlp…" : "Update yt-dlp Now") {
                if let brew = app.tools.report?.brewURL { app.tools.updateYtDlp(brew: brew) }
            }
            .disabled(app.tools.isUpdating || app.tools.report?.brewURL == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(DownloadFilter.allCases.enumerated()), id: \.element) { index, filter in
                Button(filter.title) { app.show(filter) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
        }

        CommandGroup(replacing: .help) {
            Link("Downstream on GitHub", destination: AppDelegate.links.repository)
            Link("Release Notes", destination: AppDelegate.links.releases)
            Link("Report a Problem…", destination: AppDelegate.links.issues)
            Divider()
            Link("Sites yt-dlp Supports", destination: AppDelegate.links.supportedSites)
            Divider()
            Button("Welcome Guide") { app.showWelcome() }
            Button("What's New") { app.window.whatsNew = VersionItem(version: app.updates.currentVersion) }
        }
    }
}

/// Shows first-run setup until the required tools are found, then the main window.
struct RootView: View {
    @Environment(ToolSetupModel.self) private var tools
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        Group {
            if tools.downloadTools != nil {
                MainView()
            } else {
                ToolSetupView()
            }
        }
        .frame(minWidth: 820, minHeight: 640)
        .sheet(isPresented: Binding(get: { window.showWelcome }, set: { window.showWelcome = $0 })) { WelcomeView() }
        .sheet(item: Binding(get: { window.whatsNew }, set: { window.whatsNew = $0 })) { WhatsNewView(version: $0.version) }  // room for the Add Download sheet, which can't be taller than the window
        // The first tool check runs from AppDelegate at launch.
    }
}

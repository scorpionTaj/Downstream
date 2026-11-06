import AppKit
import DownstreamCore
import SwiftUI

@main
struct DownstreamApp: App {
    // `@State` needs a macro plugin that isn't in the Command Line Tools, so app-wide
    // models are plain stored properties: the App struct is created once.
    private let tools = ToolSetupModel()
    private let downloads = DownloadManager()
    private let addDownload = AddDownloadModel()

    init() {
        // Needed when launched as a bare executable (`swift run Downstream`), and harmless inside the .app.
        NSApplication.shared.setActivationPolicy(.regular)

        // yt-dlp runs as a separate process and would keep going after the app quits.
        let downloads = downloads
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { downloads.cancelAll() }
        }
    }

    var body: some Scene {
        WindowGroup("Downstream") {
            RootView()
                .environment(tools)
                .environment(downloads)
                .environment(addDownload)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") { addDownload.present(ytDlp: tools.downloadTools?.ytDlp) }
                    .keyboardShortcut("n")
                    .disabled(tools.downloadTools == nil)
            }
        }
    }
}

/// Shows first-run setup until the required tools are found, then the main window.
struct RootView: View {
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        Group {
            if tools.downloadTools != nil {
                MainView()
            } else {
                ToolSetupView()
            }
        }
        .frame(minWidth: 620, minHeight: 540)  // tall enough for the Add Download sheet
        .task {
            if tools.report == nil { await tools.refresh() }
        }
    }
}

import AppKit
import DownstreamCore
import SwiftUI

@main
struct DownstreamApp: App {
    // `@State` needs a macro plugin that isn't in the Command Line Tools, so the app-wide
    // models live on the app delegate, which SwiftUI creates once.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    init() {
        // Needed when launched as a bare executable (`swift run Downstream`), and harmless inside the .app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Downstream") {
            RootView()
                .environment(app.tools)
                .environment(app.downloads)
                .environment(app.addDownload)
                .environment(app.window)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") { app.addDownload.present(ytDlp: app.tools.downloadTools?.ytDlp) }
                    .keyboardShortcut("n")
                    .disabled(app.tools.downloadTools == nil)
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
        .frame(minWidth: 760, minHeight: 540)  // tall enough for the Add Download sheet
        .task {
            if tools.report == nil { await tools.refresh() }
        }
    }
}

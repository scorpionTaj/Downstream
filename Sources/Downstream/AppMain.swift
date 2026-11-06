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
                .environment(app.library)
                .environment(app.settings)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") { app.addDownload.present(ytDlp: app.tools.downloadTools?.ytDlp) }
                    .keyboardShortcut("n")
                    .disabled(app.tools.downloadTools == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(app.settings)
                .environment(app.tools)
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
        .frame(minWidth: 780, minHeight: 640)  // room for the Add Download sheet, which can't be taller than the window
        // The first tool check runs from AppDelegate at launch.
    }
}

import DownstreamCore
import SwiftUI

/// "Check for Updates…": the result, release notes, and download/install with a progress bar.
struct UpdateView: View {
    @Environment(AppUpdateModel.self) private var updates

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "arrow.down.app.fill", size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.bold))
                    Text("You have Downstream \(updates.currentVersion).")
                        .foregroundStyle(.secondary)
                }
            }

            content

            HStack {
                if let page = updates.availableRelease?.pageURL {
                    Link("View on GitHub", destination: page)
                }
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 520)
        .tint(Theme.pink)
    }

    private var title: LocalizedStringKey {
        switch updates.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "You're up to date"
        case .available(let release): "Downstream \(release.version?.description ?? release.tagName) is available"
        case .downloading: "Downloading the update…"
        case .installing: "Installing…"
        case .readyToRelaunch: "Update installed"
        case .failed: "Update failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.state {
        case .idle, .checking, .installing:
            SunsetProgressBar(fraction: nil)
        case .upToDate:
            Text("Downstream \(updates.currentVersion) is the newest version.")
        case .available(let release):
            notes(release)
        case .downloading(let fraction, let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                SunsetProgressBar(fraction: fraction, height: 10)
                Text(total.map { "\(DownloadFormatting.bytes(received)) of \(DownloadFormatting.bytes($0))" }
                     ?? DownloadFormatting.bytes(received))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .readyToRelaunch:
            Text("Relaunch to start using the new version. Unfinished downloads come back paused.")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.red)
                .textSelection(.enabled)
        }
    }

    private func notes(_ release: AppRelease) -> some View {
        ScrollView {
            Text((try? AttributedString(markdown: release.notes ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(release.notes ?? ""))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(height: 160)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var buttons: some View {
        switch updates.state {
        case .available:
            Button("Later") { updates.isPresented = false }
            Button("Download and install") { updates.downloadAndInstall() }
                .buttonStyle(SunsetButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Cancel") { updates.cancelDownload() }
        case .readyToRelaunch:
            Button("Later") { updates.isPresented = false }
            Button("Relaunch now") { updates.relaunch() }
                .buttonStyle(SunsetButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close") { updates.isPresented = false }
            Button("Try again") { Task { await updates.check(userInitiated: true) } }
                .buttonStyle(SunsetButtonStyle())
        case .installing, .checking:
            EmptyView()
        case .idle, .upToDate:
            Button("OK") { updates.isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
    }
}

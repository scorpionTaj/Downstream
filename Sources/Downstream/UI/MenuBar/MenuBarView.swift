import AppKit
import DownstreamCore
import SwiftUI

/// The menu bar popover: downloads in progress, a one-click download of the copied link, and the way back to the window.
struct MenuBarView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AddDownloadModel.self) private var addDownload
    @Environment(ToolSetupModel.self) private var tools
    @Environment(MainWindowModel.self) private var window
    @Environment(\.openWindow) private var openWindow

    /// At most this many rows; the window shows the rest.
    private let rowLimit = 5

    var body: some View {
        let unfinished = downloads.jobs.filter { !$0.isFinished }
        let clipboardLink = AddDownloadModel.clipboardLink

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downstream").font(.headline)
                Spacer()
                if downloads.runningCount > 0 {
                    Text("\(downloads.runningCount) active")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }

            if unfinished.isEmpty {
                Text("No downloads in progress")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(unfinished.prefix(rowLimit)) { MenuBarRow(job: $0) }
                if unfinished.count > rowLimit {
                    Text("and \(unfinished.count - rowLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                guard let downloadTools = tools.downloadTools else { return }
                window.menuBarMessage = addDownload.downloadClipboardLink(in: downloads, tools: downloadTools)
            } label: {
                Label("Paste link and download", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(clipboardLink == nil || tools.downloadTools == nil)
            .help(clipboardLink.map { "Download \($0.absoluteString) with your default settings" } ?? "Copy a link to a video first")

            if let message = window.menuBarMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let link = clipboardLink {
                Text(link.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            HStack {
                Button("Open Downstream") { showMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { window.menuBarMessage = nil }
    }

    /// Brings the main window forward, or opens it if it was closed.
    private func showMainWindow() {
        NSApp.activate()
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

private struct MenuBarRow: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            switch job.state {
            case .downloading(let progress?) where progress.fraction != nil:
                ProgressView(value: progress.fraction!)
            case .downloading, .processing:
                ProgressView().progressViewStyle(.linear)
            default:
                EmptyView()
            }
            Text(DownloadFormatting.status(of: job))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

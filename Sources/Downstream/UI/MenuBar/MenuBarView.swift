import AppKit
import DownstreamCore
import SwiftUI

/// The menu bar popover: live downloads you can control, one-click download of the copied link,
/// recent results, and shortcuts to the window, the folder and Settings.
struct MenuBarView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AddDownloadModel.self) private var addDownload
    @Environment(ToolSetupModel.self) private var tools
    @Environment(MainWindowModel.self) private var window
    @Environment(Library.self) private var library
    @Environment(AppUpdateModel.self) private var updates
    @Environment(\.openWindow) private var openWindow

    /// At most this many rows; the window shows the rest.
    private let rowLimit = 4

    var body: some View {
        let unfinished = downloads.jobs.filter { !$0.isFinished }
        let clipboardLink = AddDownloadModel.clipboardLink

        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                if updates.isUpdateAvailable {
                    Button { showMainWindow(); updates.isPresented = true } label: {
                        Label("A new version of Downstream is ready", systemImage: "sparkles")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(SunsetButtonStyle(prominent: false))
                }

                if unfinished.isEmpty {
                    Label("No downloads in progress", systemImage: "moon.zzz")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(unfinished.prefix(rowLimit)) { MenuBarRow(job: $0) }
                    if unfinished.count > rowLimit {
                        Button("and \(unfinished.count - rowLimit) more in the window") { showMainWindow() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    bulkActions
                }

                Button {
                    guard let downloadTools = tools.downloadTools else { return }
                    window.menuBarMessage = addDownload.downloadClipboardLink(in: downloads, tools: downloadTools)
                } label: {
                    Label("Paste link and download", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SunsetButtonStyle())
                .disabled(clipboardLink == nil || tools.downloadTools == nil)
                .opacity(clipboardLink == nil ? 0.5 : 1)
                .help(clipboardLink.map { String(localized: "Download \($0.absoluteString) with your default settings") }
                      ?? String(localized: "Copy a link to a video first"))

                if let message = window.menuBarMessage {
                    Text(message).font(.caption).foregroundStyle(Theme.red)
                } else {
                    Text(clipboardLink?.absoluteString ?? String(localized: "Copy a video link, then click to download it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                recent
            }
            .padding(14)

            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { window.menuBarMessage = nil }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Downstream").font(.headline).foregroundStyle(.white)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.sunset)
    }

    private var summary: String {
        var parts: [String] = []
        if downloads.runningCount > 0 { parts.append(String(localized: "\(downloads.runningCount) downloading")) }
        if downloads.queuedCount > 0 { parts.append(String(localized: "\(downloads.queuedCount) queued")) }
        if downloads.pausedCount > 0 { parts.append(String(localized: "\(downloads.pausedCount) paused")) }
        if downloads.totalSpeed > 0 { parts.append(DownloadFormatting.speed(downloads.totalSpeed)) }
        if tools.isUpdating { parts.append(String(localized: "updating yt-dlp")) }
        return parts.isEmpty ? String(localized: "Ready") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var bulkActions: some View {
        HStack(spacing: 8) {
            if downloads.runningCount + downloads.queuedCount > 0 {
                Button("Pause all", systemImage: "pause.fill") { downloads.pauseAll() }
            }
            if downloads.pausedCount > 0 {
                Button("Resume all", systemImage: "play.fill") { downloads.resumeAll() }
            }
            Spacer()
        }
        .buttonStyle(SunsetButtonStyle(prominent: false))
        .controlSize(.small)
        .font(.caption)
    }

    /// The last three finished downloads, from History.
    @ViewBuilder
    private var recent: some View {
        let items = Array(library.history.prefix(3))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recently finished").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(items) { entry in
                    Button {
                        if let file = entry.file { DownloadRow.reveal(file) } else { window.filter = .history; showMainWindow() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.isFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(entry.isFailed ? Theme.red : Theme.green)
                            Text(entry.title).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.isFailed ? (entry.failure ?? "") : String(localized: "Show in Finder"))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Open Downstream", systemImage: "macwindow") { showMainWindow() }
            Button("Downloads folder", systemImage: "folder") {
                let folder = AppSettings.downloadFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        let style = StatusStyle(job.state)
        HStack(spacing: 10) {
            Thumbnail(url: job.thumbnailURL, width: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.state {
                case .downloading(let progress):
                    SunsetProgressBar(fraction: progress?.fraction, height: 5)
                case .processing:
                    SunsetProgressBar(fraction: nil, tint: AnyShapeStyle(Theme.purple.gradient), height: 5)
                case .paused:
                    SunsetProgressBar(fraction: job.lastProgress?.fraction ?? 0, tint: AnyShapeStyle(Theme.indigo.opacity(0.7)), height: 5)
                default:
                    EmptyView()
                }
                Text(DownloadFormatting.status(of: job))
                    .font(.caption)
                    .foregroundStyle(style.color)
                    .lineLimit(1)
            }
            if job.canPause {
                Button("Pause", systemImage: "pause.fill") { downloads.pause(job) }
                    .buttonStyle(CircleIconButtonStyle(color: Theme.indigo))
            } else if job.state == .paused {
                Button("Resume", systemImage: "play.fill") { downloads.resume(job) }
                    .buttonStyle(CircleIconButtonStyle(color: Theme.pink))
            }
            Button("Cancel", systemImage: "xmark") { downloads.cancel(job) }
                .buttonStyle(CircleIconButtonStyle(color: Theme.red))
        }
    }
}

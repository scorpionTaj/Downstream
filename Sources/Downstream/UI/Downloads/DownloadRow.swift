import AppKit
import DownstreamCore
import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(MainWindowModel.self) private var window
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: job.thumbnailURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                progressBar
                Text(DownloadFormatting.status(of: job))
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.vertical, 4)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch job.state {
        case .downloading(let progress?) where progress.fraction != nil:
            ProgressView(value: progress.fraction!)
                .accessibilityLabel("Download progress")
        case .downloading, .processing:
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Working")
        case .paused:
            ProgressView(value: job.lastProgress?.fraction ?? 0)
                .tint(.secondary)
                .accessibilityLabel("Paused")
        case .queued, .completed, .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            if job.canPause {
                iconButton("Pause", "pause.circle.fill") { downloads.pause(job) }
            }
            if job.state == .paused {
                iconButton("Resume", "play.circle.fill") { downloads.resume(job) }
            }
            if job.canRetry {
                iconButton("Retry", "arrow.clockwise.circle.fill") { downloads.retry(job) }
            }
            if isFailed {
                iconButton("Show log", "doc.text.magnifyingglass") { window.logJob = job }
            }
            if case .completed(let file) = job.state {
                iconButton("Show in Finder", "magnifyingglass.circle.fill") { Self.reveal(file) }
            }
            if job.isFinished {
                iconButton("Remove from list", "xmark") { downloads.remove(job) }
            } else {
                iconButton("Cancel", "xmark.circle.fill") { downloads.cancel(job) }
            }
        }
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(title)
    }

    @ViewBuilder
    private var menu: some View {
        if case .completed(let file) = job.state {
            Button("Show in Finder") { Self.reveal(file) }
            Button("Open") { NSWorkspace.shared.open(file) }
            Divider()
        }
        if job.canPause { Button("Pause") { downloads.pause(job) } }
        if job.state == .paused { Button("Resume") { downloads.resume(job) } }
        if job.canRetry { Button("Retry") { downloads.retry(job) } }
        Button("Copy link") { Self.copy(job.url.absoluteString) }
        Button("Show log") { window.logJob = job }
        Divider()
        if job.isFinished {
            Button("Remove from list") { downloads.remove(job) }
        } else {
            Button("Cancel download") { downloads.cancel(job) }
        }
    }

    private var isFailed: Bool {
        if case .failed = job.state { true } else { false }
    }

    /// Selects the file in Finder, or opens its folder if the file has since been moved or deleted.
    static func reveal(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

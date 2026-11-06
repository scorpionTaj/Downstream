import AppKit
import DownstreamCore
import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
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
        case .waiting, .downloading, .processing:
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Working")
        case .completed, .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if job.isActive {
            Button("Cancel", systemImage: "xmark.circle.fill") { job.cancel() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Cancel this download")
        } else {
            if case .completed(let file) = job.state {
                Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") { Self.reveal(file) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            Button("Remove", systemImage: "xmark") { downloads.remove(job) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove from the list. The file stays where it is.")
        }
    }

    @ViewBuilder
    private var menu: some View {
        if case .completed(let file) = job.state {
            Button("Show in Finder") { Self.reveal(file) }
            Button("Open") { NSWorkspace.shared.open(file) }
            Divider()
        }
        Button("Copy link") { Self.copy(job.url.absoluteString) }
        if case .failed(let message) = job.state {
            Button("Copy error") { Self.copy(message + "\n\n" + job.log.suffix(30).joined(separator: "\n")) }
        }
        Divider()
        if job.isActive {
            Button("Cancel download") { job.cancel() }
        } else {
            Button("Remove from list") { downloads.remove(job) }
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

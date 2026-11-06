import AppKit
import DownstreamCore
import SwiftUI

/// One download as a card: thumbnail, title, state chip, gradient progress and actions.
struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(MainWindowModel.self) private var window
    let job: DownloadJob

    var body: some View {
        let style = StatusStyle(job.state)
        HStack(spacing: 14) {
            Thumbnail(url: job.thumbnailURL, width: 112)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(job.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    StatusChip(style: style)
                }
                progress(style)
                HStack(spacing: 6) {
                    Text(DownloadFormatting.status(of: job))
                        .foregroundStyle(isFailed ? AnyShapeStyle(Theme.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let percent {
                        Text(percent).fontWeight(.semibold).foregroundStyle(style.color).monospacedDigit()
                    }
                }
                .font(.callout)
            }
            buttons
        }
        .card(accent: style.color)
        .contextMenu { menu }
    }

    private var percent: String? {
        if case .downloading(let progress?) = job.state, let fraction = progress.fraction {
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        }
        return nil
    }

    @ViewBuilder
    private func progress(_ style: StatusStyle) -> some View {
        switch job.state {
        case .downloading(let progress):
            SunsetProgressBar(fraction: progress?.fraction)
        case .processing:
            SunsetProgressBar(fraction: nil, tint: AnyShapeStyle(Theme.purple.gradient))
        case .paused:
            SunsetProgressBar(fraction: job.lastProgress?.fraction ?? 0, tint: AnyShapeStyle(Theme.indigo.opacity(0.7)))
        case .completed:
            SunsetProgressBar(fraction: 1, tint: AnyShapeStyle(Theme.green.gradient))
        case .queued, .failed, .cancelled:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if job.canPause {
                circle("Pause", "pause.fill", Theme.indigo) { downloads.pause(job) }
            }
            if job.state == .paused {
                circle("Resume", "play.fill", Theme.pink) { downloads.resume(job) }
            }
            if job.canRetry {
                circle("Retry", "arrow.clockwise", Theme.orange) { downloads.retry(job) }
            }
            if isFailed {
                circle("Show log", "doc.text.magnifyingglass", Theme.red) { window.logJob = job }
            }
            if case .completed(let file) = job.state {
                circle("Show in Finder", "magnifyingglass", Theme.green) { Self.reveal(file) }
            }
            if job.isFinished {
                circle("Remove from list", "xmark", .gray) { downloads.remove(job) }
            } else {
                circle("Cancel", "xmark", Theme.red) { downloads.cancel(job) }
            }
        }
    }

    private func circle(_ title: LocalizedStringKey, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .buttonStyle(CircleIconButtonStyle(color: color))
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

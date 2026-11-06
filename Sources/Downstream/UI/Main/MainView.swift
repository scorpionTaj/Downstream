import DownstreamCore
import SwiftUI

struct MainView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AddDownloadModel.self) private var addDownload
    @Environment(ToolSetupModel.self) private var tools
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        @Bindable var addDownload = addDownload
        @Bindable var window = window

        NavigationSplitView {
            List(selection: Binding(get: { window.filter }, set: { window.filter = $0 ?? .all })) {
                ForEach(DownloadFilter.allCases) { filter in
                    let count = downloads.jobs.filter(filter.includes).count
                    Label(filter.title, systemImage: filter.symbol)
                        .badge(filter == .all ? 0 : count)
                        .tag(filter)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                list
                Divider()
                footer
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Clear finished", systemImage: "trash") { downloads.removeFinished() }
                    .help("Remove completed, failed and cancelled downloads from the list. Files stay where they are.")
                    .disabled(!downloads.jobs.contains(where: \.isFinished))
                Button("Add download", systemImage: "plus") { addDownload.present(ytDlp: tools.downloadTools?.ytDlp) }
                    .help("Add a download (⌘N)")
            }
        }
        .sheet(isPresented: $addDownload.isPresented) {
            AddDownloadSheet()
        }
        .sheet(item: $window.logJob) { job in
            LogSheet(job: job)
        }
        .onChange(of: downloads.jobs.first?.id) {
            // A new download should be visible, whichever filter is selected.
            if window.filter == .completed || window.filter == .failed { window.filter = .all }
        }
    }

    @ViewBuilder
    private var list: some View {
        let visible = downloads.jobs.filter(window.filter.includes)
        if downloads.jobs.isEmpty {
            ContentUnavailableView {
                Label("No downloads yet", systemImage: "arrow.down.circle")
            } description: {
                Text("Paste a link from YouTube, Vimeo or hundreds of other sites.")
            } actions: {
                Button("Add download") { addDownload.present(ytDlp: tools.downloadTools?.ytDlp) }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView(window.filter.emptyMessage, systemImage: window.filter.symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visible) { job in
                DownloadRow(job: job)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Text(versionSummary)
            if let command = tools.report?.installCommand {
                Text("· Optional: \(command)").textSelection(.enabled)
            }
            Spacer()
            Text(activitySummary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var versionSummary: String {
        (tools.report?.statuses ?? [])
            .filter(\.isFound)
            .map { "\($0.tool.displayName) \($0.version ?? "?")" }
            .joined(separator: " · ")
    }

    private var activitySummary: String {
        var parts: [String] = []
        if downloads.runningCount > 0 { parts.append("\(downloads.runningCount) active") }
        if downloads.queuedCount > 0 { parts.append("\(downloads.queuedCount) queued") }
        if downloads.totalSpeed > 0 { parts.append(DownloadFormatting.speed(downloads.totalSpeed)) }
        return parts.joined(separator: " · ")
    }
}

/// yt-dlp's output for one download, for working out why it failed.
struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.headline).lineLimit(2)
            if case .failed(let message) = job.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ScrollView {
                Text(job.log.isEmpty ? "yt-dlp didn't print anything." : job.log.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(job.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy log") { DownloadRow.copy(job.log.joined(separator: "\n")) }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

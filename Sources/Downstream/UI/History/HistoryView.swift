import AppKit
import DownstreamCore
import SwiftUI

/// Finished downloads, completed and failed, kept across launches.
struct HistoryView: View {
    @Environment(Library.self) private var library
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        let entries = filtered

        VStack(spacing: 0) {
            Picker("Show", selection: $window.historyFilter) {
                Text("All").tag(HistoryFilter.all)
                Text("Completed").tag(HistoryFilter.completed)
                Text("Failed").tag(HistoryFilter.failed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.bottom, 12)

            if library.history.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "No history yet",
                               message: "Finished downloads appear here, even after you clear them from the list.") { EmptyView() }
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: window.historySearch)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { HistoryRow(entry: $0) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
        .searchable(text: $window.historySearch, prompt: "Search history")
        .confirmationDialog("Clear all history?", isPresented: $window.isConfirmingClearHistory) {
            Button("Clear history", role: .destructive) { library.clearHistory() }
        } message: {
            Text("This removes \(library.history.count) entries from Downstream. The downloaded files stay where they are.")
        }
    }

    private var filtered: [HistoryEntry] {
        let query = window.historySearch.trimmingCharacters(in: .whitespaces)
        return library.history.filter { entry in
            switch window.historyFilter {
            case .all: break
            case .completed: if entry.isFailed { return false }
            case .failed: if !entry.isFailed { return false }
            }
            return query.isEmpty
                || entry.title.localizedCaseInsensitiveContains(query)
                || entry.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct HistoryRow: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(ToolSetupModel.self) private var tools
    @Environment(MainWindowModel.self) private var window
    let entry: HistoryEntry

    var body: some View {
        let file = entry.file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let color = entry.isFailed ? Theme.red : Theme.green
        HStack(spacing: 14) {
            Thumbnail(url: entry.thumbnailURL, width: 88)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    StatusChip(style: entry.isFailed ? StatusStyle(.failed("")) : StatusStyle(.completed(URL(fileURLWithPath: "/"))))
                }
                Text(details(file: file))
                    .font(.callout)
                    .foregroundStyle(entry.isFailed ? AnyShapeStyle(Theme.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                circle(entry.isFailed ? "Try again" : "Download again", entry.isFailed ? "arrow.clockwise" : "arrow.down",
                       Theme.orange, action: downloadAgain)
                    .disabled(tools.downloadTools == nil)
                if let file {
                    circle("Show in Finder", "magnifyingglass", Theme.green) { DownloadRow.reveal(file) }
                }
                circle("Remove from history", "xmark", .gray) { library.removeHistory(entry) }
            }
        }
        .card(accent: color, padding: 12)
        .contextMenu {
            if let file {
                Button("Open") { NSWorkspace.shared.open(file) }
                Button("Show in Finder") { DownloadRow.reveal(file) }
                Divider()
            }
            Button(entry.isFailed ? "Try again" : "Download again", action: downloadAgain)
            Button("Copy link") { Clipboard.copy(entry.url.absoluteString) }
            if let failure = entry.failure { Button("Copy error") { Clipboard.copy(failure) } }
            Divider()
            Button("Remove from history") { library.removeHistory(entry) }
        }
    }

    private func details(file: URL?) -> String {
        let date = entry.completedAt.formatted(date: .abbreviated, time: .shortened)
        if let failure = entry.failure { return "\(date) · \(failure)" }
        var parts: [String] = []
        if let saved = entry.file { parts.append(saved.pathExtension.uppercased()) }
        if let size = entry.fileSize { parts.append(DownloadFormatting.bytes(size)) }
        parts.append(date)
        if file == nil { parts.append(String(localized: "File moved or deleted")) }
        return parts.joined(separator: " · ")
    }

    private func downloadAgain() {
        guard let downloadTools = tools.downloadTools else { return }
        downloads.downloadAgain(entry, outputDirectory: AppSettings.downloadFolder, tools: downloadTools)
        window.filter = .all
    }
}

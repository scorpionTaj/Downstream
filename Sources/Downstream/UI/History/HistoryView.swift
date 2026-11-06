import AppKit
import DownstreamCore
import SwiftUI

/// Completed downloads, kept across launches.
struct HistoryView: View {
    @Environment(Library.self) private var library
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        let entries = filtered

        Group {
            if library.history.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Completed downloads appear here, even after you clear them from the list."))
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: window.historySearch)
            } else {
                List(entries) { HistoryRow(entry: $0) }
                    .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $window.historySearch, prompt: "Search history")
        .confirmationDialog("Clear all history?", isPresented: $window.isConfirmingClearHistory) {
            Button("Clear history", role: .destructive) { library.clearHistory() }
        } message: {
            Text("This removes \(library.history.count) entries from Downstream. The downloaded files stay where they are.")
        }
    }

    private var filtered: [HistoryEntry] {
        let query = window.historySearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.history }
        return library.history.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
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
        let exists = FileManager.default.fileExists(atPath: entry.file.path)
        HStack(spacing: 12) {
            Thumbnail(url: entry.thumbnailURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details(fileExists: exists))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                iconButton("Download again", "arrow.down.circle.fill", action: downloadAgain)
                    .disabled(tools.downloadTools == nil)
                if exists {
                    iconButton("Show in Finder", "magnifyingglass.circle.fill") { DownloadRow.reveal(entry.file) }
                }
                iconButton("Remove from history", "xmark") { library.removeHistory(entry) }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if exists {
                Button("Open") { NSWorkspace.shared.open(entry.file) }
                Button("Show in Finder") { DownloadRow.reveal(entry.file) }
                Divider()
            }
            Button("Download again", action: downloadAgain)
            Button("Copy link") { DownloadRow.copy(entry.url.absoluteString) }
            Divider()
            Button("Remove from history") { library.removeHistory(entry) }
        }
    }

    private func details(fileExists: Bool) -> String {
        var parts = [entry.file.pathExtension.uppercased()]
        if let size = entry.fileSize { parts.append(DownloadFormatting.bytes(size)) }
        parts.append(entry.completedAt.formatted(date: .abbreviated, time: .shortened))
        if !fileExists { parts.append("File moved or deleted") }
        return parts.joined(separator: " · ")
    }

    private func downloadAgain() {
        guard let downloadTools = tools.downloadTools else { return }
        downloads.downloadAgain(entry, outputDirectory: AppSettings.downloadFolder, tools: downloadTools)
        window.filter = .all
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(title)
    }
}

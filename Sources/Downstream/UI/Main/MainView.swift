import DownstreamCore
import SwiftUI

struct MainView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AddDownloadModel.self) private var addDownload
    @Environment(ToolSetupModel.self) private var tools
    @Environment(MainWindowModel.self) private var window
    @Environment(Library.self) private var library
    @Environment(AppUpdateModel.self) private var updates

    var body: some View {
        @Bindable var addDownload = addDownload
        @Bindable var window = window
        @Bindable var updates = updates

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 245, ideal: 255, max: 320)
        } detail: {
            VStack(spacing: 0) {
                header
                if window.filter == .history { HistoryView() } else { list }
                footer
            }
            .background(Theme.backdrop)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if window.filter == .history {
                    Button("Clear history", systemImage: "trash") { window.isConfirmingClearHistory = true }
                        .help("Remove every entry from History. Files stay where they are.")
                        .disabled(library.history.isEmpty)
                } else {
                    Button("Clear finished", systemImage: "trash") { downloads.removeFinished() }
                        .help("Remove completed, failed and cancelled downloads from the list. Files stay where they are.")
                        .disabled(!downloads.jobs.contains(where: \.isFinished))
                }
            }
        }
        .sheet(isPresented: $addDownload.isPresented) { AddDownloadSheet() }
        .sheet(item: $window.logJob) { LogSheet(job: $0) }
        .sheet(isPresented: $updates.isPresented) { UpdateView() }
        .onChange(of: downloads.jobs.first?.id) {
            // A new download should be visible, whichever filter is selected.
            if [.completed, .failed, .history].contains(window.filter) { window.filter = .all }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { window.filter }, set: { window.filter = $0 ?? .all })) {
            Section("Downloads") {
                ForEach(DownloadFilter.listFilters) { filter in
                    sidebarRow(filter, count: filter == .all ? nil : downloads.jobs.filter(filter.includes).count)
                }
            }
            Section("Library") {
                sidebarRow(.history, count: nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if updates.isUpdateAvailable {
                Button { updates.isPresented = true } label: {
                    Label("Update available", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SunsetButtonStyle())
                .padding(12)
            }
        }
    }

    private func sidebarRow(_ filter: DownloadFilter, count: Int?) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: filter.symbol, fill: filter.tileFill, size: 24)
            Text(filter.title)
            Spacer()
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(filter.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(filter.color)
            }
        }
        .padding(.vertical, 3)
        .tag(filter)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: window.filter.symbol, fill: window.filter.tileFill, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.filter.title).font(.title2.weight(.bold))
                Text(headerSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                addDownload.present(ytDlp: tools.downloadTools?.ytDlp)
            } label: {
                Label("Add download", systemImage: "plus")
            }
            .buttonStyle(SunsetButtonStyle())
            .keyboardShortcut("n")
            .help("Add a download (⌘N)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var headerSummary: String {
        if window.filter == .history {
            let failed = library.history.filter(\.isFailed).count
            return String(localized: "Remembered: \(library.history.count) · Failed: \(failed)")
        }
        let parts = DownloadFormatting.queueSummary(running: downloads.runningCount, queued: downloads.queuedCount,
                                                    paused: downloads.pausedCount, speed: downloads.totalSpeed)
        return parts.isEmpty ? String(localized: "Nothing in progress") : parts.joined(separator: " · ")
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let visible = downloads.jobs.filter(window.filter.includes)
        if downloads.jobs.isEmpty {
            EmptyStateView(symbol: "arrow.down", title: "Start your first download",
                           message: "Paste a link from YouTube, Vimeo or hundreds of other sites.") {
                Button { addDownload.present(ytDlp: tools.downloadTools?.ytDlp) } label: {
                    Label("Add download", systemImage: "plus")
                }
                .buttonStyle(SunsetButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(symbol: window.filter.symbol, title: window.filter.emptyMessage, message: nil) { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(visible) { DownloadRow(job: $0) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(tools.report?.statuses.filter(\.isFound) ?? []) { status in
                Text("\(status.tool.displayName) \(status.version ?? "?")")
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            if tools.isUpdating {
                ProgressView().controlSize(.mini)
                Text("Updating yt-dlp…")
            }
            Spacer()
            if let error = library.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension DownloadFilter {
    var color: Color {
        switch self {
        case .all: Theme.orange
        case .downloading: Theme.pink
        case .queued: Theme.amber
        case .completed: Theme.green
        case .failed: Theme.red
        case .history: Theme.purple
        }
    }

    var tileFill: AnyShapeStyle {
        self == .all ? AnyShapeStyle(Theme.sunsetDiagonal) : AnyShapeStyle(color.gradient)
    }
}

/// A big friendly placeholder: gradient circle, title, message and an optional action.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(Theme.sunsetDiagonal, in: Circle())
                .shadow(color: Theme.pink.opacity(0.35), radius: 14, y: 6)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// yt-dlp's output for one download, for working out why it failed.
struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "doc.text.magnifyingglass", fill: AnyShapeStyle(StatusStyle(job.state).color.gradient), size: 36)
                Text(job.title).font(.headline).lineLimit(2)
            }
            if case .failed(let message) = job.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.red)
                    .textSelection(.enabled)
            }
            ScrollView {
                Text(job.log.isEmpty ? String(localized: "yt-dlp didn't print anything.") : job.log.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(job.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy log") { Clipboard.copy(job.log.joined(separator: "\n")) }
                Button("Close") { dismiss() }
                    .buttonStyle(SunsetButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 440)
    }
}

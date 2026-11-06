import DownstreamCore
import SwiftUI

/// The download list. Milestone 4 adds the sidebar (Downloading · Queued · Completed · Failed · History).
struct MainView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AddDownloadModel.self) private var addDownload
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        @Bindable var addDownload = addDownload

        VStack(spacing: 0) {
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
            } else {
                List(downloads.jobs) { job in
                    DownloadRow(job: job)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Clear finished", systemImage: "trash") { downloads.removeFinished() }
                    .help("Remove finished downloads from the list")
                    .disabled(!downloads.jobs.contains { !$0.isActive })
                Button("Add download", systemImage: "plus") { addDownload.present(ytDlp: tools.downloadTools?.ytDlp) }
                    .help("Add a download (⌘N)")
            }
        }
        .sheet(isPresented: $addDownload.isPresented) {
            AddDownloadSheet()
        }
    }

    private var footer: some View {
        HStack {
            Text(versionSummary)
            if let command = tools.report?.installCommand {
                Text("· Optional: \(command)").textSelection(.enabled)
            }
            Spacer()
            if downloads.activeCount > 0 {
                Text(activitySummary)
            }
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
        let active = "\(downloads.activeCount) active"
        let speed = downloads.totalSpeed
        return speed > 0 ? "\(active) · \(DownloadFormatting.speed(speed))" : active
    }
}

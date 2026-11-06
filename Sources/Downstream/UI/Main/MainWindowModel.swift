import DownstreamCore
import Observation

/// The sidebar's filters. History arrives in milestone 5.
enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, downloading, queued, completed, failed

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All downloads"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .queued: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// What the list shows when this filter matches nothing.
    var emptyMessage: String {
        switch self {
        case .all: "No downloads"
        case .downloading: "Nothing downloading"
        case .queued: "Nothing queued or paused"
        case .completed: "No completed downloads"
        case .failed: "No failed or cancelled downloads"
        }
    }

    @MainActor
    func includes(_ job: DownloadJob) -> Bool {
        switch self {
        case .all: true
        case .downloading: job.isRunning
        case .queued: job.state == .queued || job.state == .paused
        case .completed: if case .completed = job.state { true } else { false }
        case .failed: job.state == .cancelled || { if case .failed = job.state { true } else { false } }()
        }
    }
}

/// Window state that would be `@State` if the Command Line Tools had its macro plugin.
@MainActor
@Observable
final class MainWindowModel {
    var filter: DownloadFilter = .all
    /// The job whose log sheet is open.
    var logJob: DownloadJob?
}

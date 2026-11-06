import AppKit
import DownstreamCore
import Observation

/// State for checking and installing Downstream's tools.
@MainActor
@Observable
final class ToolSetupModel {
    /// The latest check, or nil before the first one finishes.
    private(set) var report: ToolReport?
    private(set) var isChecking = false
    /// True right after the install command was copied, until the next check.
    private(set) var didCopyCommand = false

    private(set) var isUpdating = false
    /// Homebrew's output from the last update.
    private(set) var updateOutput: [String] = []
    /// One line saying how the last update went.
    private(set) var updateResult: String?

    private let locator: ToolLocator

    /// Called after every check, e.g. to restore saved downloads once the tools are found.
    var onRefresh: (() -> Void)?

    /// The tools downloads use, or nil until the required ones are found.
    var downloadTools: DownloadTools? { report.flatMap(DownloadTools.init(report:)) }

    init(defaults: UserDefaults = .standard) {
        // For testing the setup screen without uninstalling anything:
        //   open build/Downstream.app --args -DownstreamToolSearchPath /nonexistent
        if let path = defaults.string(forKey: "DownstreamToolSearchPath") {
            locator = ToolLocator(searchDirectories: path.split(separator: ":").map(String.init))
        } else {
            locator = ToolLocator()
        }
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        didCopyCommand = false
        report = await locator.check(overrides: AppSettings.toolOverrides)
        isChecking = false
        onRefresh?()
    }

    /// Downloads to hold while yt-dlp is replaced: Python loads its modules lazily, so a download running
    /// during `brew upgrade` can break when the old version's files disappear.
    weak var downloads: DownloadManager?

    /// yt-dlp at `url` is Homebrew's (its real location is inside a Cellar), so `brew upgrade` can update it.
    static func isHomebrewManaged(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.contains("/Cellar/")
    }

    /// Updates yt-dlp in the background if automatic updates are on, a week has passed, and nothing is downloading.
    func updateYtDlpIfDue() {
        guard AppSettings.autoUpdateYtDlp, !isUpdating,
              let brew = report?.brewURL, let ytDlp = report?[.ytDlp]?.url, Self.isHomebrewManaged(ytDlp),
              (downloads?.runningCount ?? 0) == 0
        else { return }
        if let last = AppSettings.lastYtDlpUpdate, Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        updateYtDlp(brew: brew)
    }

    /// Runs `brew upgrade yt-dlp`, showing its output, then checks the tools again. Waits for
    /// running downloads first: Python loads its modules lazily, so replacing yt-dlp's files
    /// under a running download can break it. (No new ones start while the queue is held.)
    func updateYtDlp(brew: URL) {
        guard !isUpdating else { return }
        isUpdating = true
        updateOutput = []
        updateResult = nil
        downloads?.isHeld = true
        Task {
            defer {
                downloads?.isHeld = false
                isUpdating = false
            }
            do {
                while let running = downloads?.runningCount, running > 0 {
                    updateResult = String(localized: "Waiting for the running downloads to finish…")
                    try await Task.sleep(for: .seconds(1))
                }
                updateResult = nil
                let before = report?[.ytDlp]?.version
                let running = try ProcessRunner.start(brew, arguments: ["upgrade", "yt-dlp"])
                for try await line in running.lines where !line.text.isEmpty {
                    updateOutput.append(line.text)
                }
                await refresh()
                AppSettings.lastYtDlpUpdate = Date()
                let after = report?[.ytDlp]?.version ?? "?"
                updateResult = after == before
                    ? String(localized: "yt-dlp \(after) is the latest version.")
                    : String(localized: "Updated yt-dlp from \(before ?? "?") to \(after).")
            } catch let ProcessError.failed(code, tail) {
                updateResult = String(localized: "Homebrew stopped with status \(Int(code)).")
                if updateOutput.isEmpty { updateOutput = tail }
            } catch {
                updateResult = String(localized: "Couldn't run Homebrew: \(error.localizedDescription)")
            }
        }
    }

    func copyInstallCommand() {
        guard let command = report?.installCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopyCommand = true
    }
}

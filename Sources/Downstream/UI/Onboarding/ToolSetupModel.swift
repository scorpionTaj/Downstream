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

    /// Runs `brew upgrade yt-dlp`, showing its output, then checks the tools again.
    func updateYtDlp(brew: URL) {
        guard !isUpdating else { return }
        let before = report?[.ytDlp]?.version
        isUpdating = true
        updateOutput = []
        updateResult = nil
        Task {
            do {
                let running = try ProcessRunner.start(brew, arguments: ["upgrade", "yt-dlp"])
                for try await line in running.lines where !line.text.isEmpty {
                    updateOutput.append(line.text)
                }
                await refresh()
                let after = report?[.ytDlp]?.version
                updateResult = after == before
                    ? "yt-dlp \(after ?? "") is the latest version."
                    : "Updated yt-dlp from \(before ?? "?") to \(after ?? "?")."
            } catch let ProcessError.failed(code, tail) {
                updateResult = "Homebrew stopped with status \(code)."
                if updateOutput.isEmpty { updateOutput = tail }
            } catch {
                updateResult = "Couldn't run Homebrew: \(error)"
            }
            isUpdating = false
        }
    }

    func copyInstallCommand() {
        guard let command = report?.installCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopyCommand = true
    }
}

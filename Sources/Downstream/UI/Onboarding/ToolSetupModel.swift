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
        report = await locator.check()
        isChecking = false
        onRefresh?()
    }

    func copyInstallCommand() {
        guard let command = report?.installCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopyCommand = true
    }
}

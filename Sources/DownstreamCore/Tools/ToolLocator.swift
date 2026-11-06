import Foundation

/// An external command-line tool Downstream drives.
public enum Tool: String, CaseIterable, Sendable, Identifiable {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case aria2c

    public var id: String { rawValue }

    /// The executable's file name.
    public var executableName: String { rawValue }

    /// The Homebrew formula that installs it.
    public var brewFormula: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .aria2c: "aria2"
        }
    }

    /// The name shown in the UI.
    public var displayName: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .aria2c: "aria2"
        }
    }

    /// The app can't download anything without the required tools. aria2 only speeds downloads up.
    public var isRequired: Bool { self != .aria2c }

    var versionArguments: [String] {
        switch self {
        case .ffmpeg: ["-version"]
        case .ytDlp, .aria2c: ["--version"]
        }
    }
}

/// What the locator found for one tool.
public struct ToolStatus: Sendable, Equatable, Identifiable {
    public let tool: Tool
    /// Where the executable is, or nil when it wasn't found.
    public let url: URL?
    /// The version it reported, or nil when it was missing or didn't answer.
    public let version: String?

    public var id: Tool { tool }
    public var isFound: Bool { url != nil }

    public init(tool: Tool, url: URL?, version: String?) {
        self.tool = tool
        self.url = url
        self.version = version
    }
}

/// The result of one full check.
public struct ToolReport: Sendable, Equatable {
    public let statuses: [ToolStatus]
    /// Where `brew` is, or nil when Homebrew isn't installed.
    public let brewURL: URL?

    public init(statuses: [ToolStatus], brewURL: URL?) {
        self.statuses = statuses
        self.brewURL = brewURL
    }

    public subscript(tool: Tool) -> ToolStatus? { statuses.first { $0.tool == tool } }

    /// True when every required tool was found.
    public var isReady: Bool { statuses.allSatisfy { $0.isFound || !$0.tool.isRequired } }

    /// The formulas still to install, in a stable order.
    public var missingFormulas: [String] { statuses.filter { !$0.isFound }.map(\.tool.brewFormula) }

    /// The command that installs everything missing, or nil when nothing is missing.
    public var installCommand: String? {
        missingFormulas.isEmpty ? nil : "brew install " + missingFormulas.joined(separator: " ")
    }
}

/// Finds Downstream's tools.
///
/// GUI apps don't inherit the login shell's `PATH`, so this never relies on it.
/// It checks a user-chosen override first, then Homebrew's prefixes.
public struct ToolLocator: Sendable {
    /// Apple Silicon Homebrew first, then Intel Homebrew.
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public var searchDirectories: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        searchDirectories: [String] = ToolLocator.homebrewDirectories,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.searchDirectories = searchDirectories
        self.isExecutable = isExecutable
    }

    /// The executable for `tool`. An override that isn't executable is ignored, and the search falls back to Homebrew's directories.
    public func locate(_ tool: Tool, override: String? = nil) -> URL? {
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return firstExecutable(named: tool.executableName)
    }

    /// Where `brew` is, if Homebrew is installed.
    public func locateBrew() -> URL? { firstExecutable(named: "brew") }

    /// Finds every tool and asks each one for its version.
    public func check(overrides: [Tool: String] = [:]) async -> ToolReport {
        var statuses: [ToolStatus] = []
        for tool in Tool.allCases {
            let url = locate(tool, override: overrides[tool])
            var version: String?
            if let url, let output = try? await ProcessRunner.output(of: url, arguments: tool.versionArguments, timeout: .seconds(10)) {
                version = ToolLocator.parseVersion(of: tool, from: output)
            }
            statuses.append(ToolStatus(tool: tool, url: url, version: version))
        }
        return ToolReport(statuses: statuses, brewURL: locateBrew())
    }

    /// Pulls the version number out of a tool's version output.
    ///
    /// - yt-dlp prints `2026.10.22`
    /// - ffmpeg prints `ffmpeg version 8.0 Copyright …`
    /// - aria2c prints `aria2 version 1.37.0`
    public static func parseVersion(of tool: Tool, from output: String) -> String? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = firstLine.split(separator: " ")
        switch tool {
        case .ytDlp:
            return words.first.map(String.init)
        case .ffmpeg, .aria2c:
            guard let index = words.firstIndex(of: "version"), words.indices.contains(index + 1) else { return nil }
            return String(words[index + 1])
        }
    }

    private func firstExecutable(named name: String) -> URL? {
        for directory in searchDirectories {
            let path = (directory as NSString).appendingPathComponent(name)
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

import Foundation

/// CHANGELOG.md (Keep a Changelog style) split into releases, for the About tab and "What's New".
public struct Changelog: Sendable, Equatable {
    public struct Release: Sendable, Equatable, Identifiable {
        public var version: String
        public var date: String?
        /// Section name ("Added", "Fixed"…) and its bullet points, in file order.
        public var sections: [(title: String, items: [String])]

        public var id: String { version }

        public static func == (lhs: Release, rhs: Release) -> Bool {
            lhs.version == rhs.version && lhs.date == rhs.date
                && lhs.sections.map(\.title) == rhs.sections.map(\.title)
                && lhs.sections.map(\.items) == rhs.sections.map(\.items)
        }
    }

    public var releases: [Release]

    /// Parses `## [1.2.0] - 2026-11-06` headings, `### Added` sections and `- item` bullets.
    /// Anything else (the intro, link references) is ignored.
    public init(markdown: String) {
        var releases: [Release] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let heading = line.dropFirst(3)
                // `## [1.2.0] - 2026-11-06`. The version is read from between the brackets when
                // they're there — Keep-a-Changelog requires them, and the version can itself
                // contain hyphens (`1.2.0-beta`), which would break a split on the first "-".
                // Bracket-less headings fall back to that split.
                let version: String
                let remainder: Substring
                let open = heading.firstIndex(of: "[")
                let close = heading.firstIndex(of: "]")
                if let open, let close, open < close {
                    version = String(heading[heading.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                    remainder = heading[heading.index(after: close)...]
                } else {
                    let parts = heading.split(separator: "-", maxSplits: 1)
                    version = (parts.first.map(String.init) ?? "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    remainder = parts.count > 1 ? parts[1] : ""
                }
                let date = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                releases.append(Release(version: version, date: date.isEmpty ? nil : date, sections: []))
            } else if line.hasPrefix("### "), !releases.isEmpty {
                releases[releases.count - 1].sections.append((String(line.dropFirst(4)), []))
            } else if line.hasPrefix("- "), !releases.isEmpty {
                if releases[releases.count - 1].sections.isEmpty {
                    releases[releases.count - 1].sections.append(("Changes", []))
                }
                let last = releases[releases.count - 1].sections.count - 1
                releases[releases.count - 1].sections[last].items.append(String(line.dropFirst(2)))
            }
        }
        self.releases = releases
    }

    /// The release for `version` (e.g. "1.2.0"), if listed.
    public func release(_ version: String) -> Release? {
        releases.first { $0.version == version }
    }

    /// The markdown of one release's section, for GitHub release notes.
    public static func notes(for version: String, in markdown: String) -> String? {
        var collecting = false
        var lines: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if collecting { break }
                collecting = line.contains("[\(version)]")
                continue
            }
            if collecting { lines.append(line) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

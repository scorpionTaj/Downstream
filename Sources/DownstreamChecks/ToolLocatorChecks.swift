import Foundation
@testable import DownstreamCore

func toolLocatorChecks() async {
    await suite("parseVersion") {
        expectEqual(ToolLocator.parseVersion(of: .ytDlp, from: "2026.10.22\n"), "2026.10.22")
        expectEqual(
            ToolLocator.parseVersion(of: .ffmpeg, from: "ffmpeg version 8.0 Copyright (c) 2000-2025 the FFmpeg developers\nbuilt with clang"),
            "8.0")
        expectEqual(
            ToolLocator.parseVersion(of: .aria2c, from: "aria2 version 1.37.0\nCopyright (C) 2006, 2019 Tatsuhiro Tsujikawa"),
            "1.37.0")
        expectEqual(ToolLocator.parseVersion(of: .ffmpeg, from: "garbage"), nil)
        expectEqual(ToolLocator.parseVersion(of: .ytDlp, from: ""), nil)
    }

    await suite("locate: search order and overrides") {
        let present: Set<String> = ["/usr/local/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/custom/yt-dlp"]
        let locator = ToolLocator(isExecutable: { present.contains($0) })

        expectEqual(locator.locate(.ffmpeg)?.path, "/opt/homebrew/bin/ffmpeg")   // Apple Silicon prefix wins
        expectEqual(locator.locate(.ytDlp)?.path, "/usr/local/bin/yt-dlp")        // falls back to Intel prefix
        expectEqual(locator.locate(.aria2c), nil)
        expectEqual(locator.locate(.ytDlp, override: "/custom/yt-dlp")?.path, "/custom/yt-dlp")
        expectEqual(locator.locate(.ytDlp, override: "/missing/yt-dlp")?.path, "/usr/local/bin/yt-dlp")  // bad override ignored
        expectEqual(locator.locate(.ytDlp, override: "")?.path, "/usr/local/bin/yt-dlp")
    }

    await suite("ToolReport readiness and install command") {
        let url = URL(fileURLWithPath: "/x")
        let onlyAriaMissing = ToolReport(statuses: [
            ToolStatus(tool: .ytDlp, url: url, version: "1"),
            ToolStatus(tool: .ffmpeg, url: url, version: "1"),
            ToolStatus(tool: .aria2c, url: nil, version: nil),
        ], brewURL: url)
        expect(onlyAriaMissing.isReady, "aria2 is optional")
        expectEqual(onlyAriaMissing.installCommand, "brew install aria2")

        let ytMissing = ToolReport(statuses: [
            ToolStatus(tool: .ytDlp, url: nil, version: nil),
            ToolStatus(tool: .ffmpeg, url: url, version: "1"),
            ToolStatus(tool: .aria2c, url: nil, version: nil),
        ], brewURL: nil)
        expect(!ytMissing.isReady, "yt-dlp is required")
        expectEqual(ytMissing.installCommand, "brew install yt-dlp aria2")

        let all = ToolReport(statuses: Tool.allCases.map { ToolStatus(tool: $0, url: url, version: "1") }, brewURL: url)
        expectEqual(all.installCommand, nil)
    }

    await suite("check: empty search path finds nothing") {
        let report = await ToolLocator(searchDirectories: []).check()
        expect(report.statuses.allSatisfy { !$0.isFound }, "nothing should be found")
        expect(!report.isReady, "not ready without tools")
        expectEqual(report.brewURL, nil)
    }

    await suite("check: real tools on this Mac (skipped if absent)") {
        let report = await ToolLocator().check()
        for status in report.statuses where status.isFound {
            expect(status.version != nil, "\(status.tool.displayName) at \(status.url!.path) reported no version")
            print("  · \(status.tool.displayName) \(status.version ?? "?") at \(status.url!.path)")
        }
    }
}

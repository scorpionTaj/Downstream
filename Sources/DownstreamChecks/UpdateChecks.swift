import Foundation
@testable import DownstreamCore

@MainActor
func updateChecks() async {
    await suite("AppVersion ordering") {
        expect(AppVersion("1.0.0")! < AppVersion("1.0.1")!, "patch")
        expect(AppVersion("v1.9.0")! < AppVersion("1.10.0")!, "numeric, not text, comparison")
        expect(AppVersion("1.2")! == AppVersion("1.2.0")!, "missing parts are 0")
        expect(AppVersion("2.0.0-beta")! == AppVersion("2.0.0")!, "suffixes ignored")
        expectEqual(AppVersion("abc"), nil)
        expectEqual(AppVersion("")?.description, nil)
        expectEqual(AppVersion("v3.1.4")?.description, "3.1.4")
    }

    await suite("Changelog parsing (the real CHANGELOG.md)") {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let changelog = Changelog(markdown: text)
        expect(changelog.releases.count >= 4, "has releases")
        let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/Info.plist")
        let version = NSDictionary(contentsOf: infoPlist)?["CFBundleShortVersionString"] as? String ?? "?"
        expectEqual(changelog.releases.first?.version, version)   // CHANGELOG.md is updated with every release
        expect(changelog.release(version)?.sections.isEmpty == false, "the current version has entries")
        let notes = Changelog.notes(for: version, in: text) ?? ""
        expect(notes.hasPrefix("### "), "release notes start at the first section: \(notes.prefix(20))")
        expect(!notes.contains("## ["), "release notes stop before the previous version")

        let sample = Changelog(markdown: "# Title\nintro\n## [2.0.0] - 2026-01-01\n### Added\n- One\n- Two\n### Fixed\n- Three\n## [1.0.0]\n- Loose\n")
        expectEqual(sample.releases.map(\.version), ["2.0.0", "1.0.0"])
        expectEqual(sample.releases[0].date, "2026-01-01")
        expectEqual(sample.releases[0].sections.map(\.title), ["Added", "Fixed"])
        expectEqual(sample.releases[0].sections[0].items, ["One", "Two"])
        expectEqual(sample.releases[1].sections.first?.items, ["Loose"])

        // A version may contain hyphens; only the date after `] - ` may be split off it.
        let prerelease = Changelog(markdown: "## [1.2.0-beta] - 2026-02-03\n### Fixed\n- X\n## 0.9 - 2026-01-02\n- Y\n")
        expectEqual(prerelease.releases.map(\.version), ["1.2.0-beta", "0.9"])
        expectEqual(prerelease.releases[0].date, "2026-02-03")
        expectEqual(prerelease.releases[1].date, "2026-01-02")
        expectEqual(prerelease.releases[0].sections.first?.items, ["X"])
    }

    await suite("AppRelease decoding and update decision") {
        let json = #"""
        {"tag_name": "v1.2.0", "name": "Downstream 1.2.0", "body": "Notes", "html_url": "https://github.com/scorpionTaj/Downstream/releases/tag/v1.2.0",
         "assets": [
           {"name": "Downstream-1.2.0.dmg.sha256", "browser_download_url": "https://example.com/a.sha256", "size": 90},
           {"name": "Downstream-1.2.0.dmg", "browser_download_url": "https://example.com/a.dmg", "size": 2000000}],
         "extra": {"ignored": true}}
        """#
        let release = try JSONDecoder().decode(AppRelease.self, from: Data(json.utf8))
        expectEqual(release.version?.description, "1.2.0")
        expectEqual(release.diskImage?.name, "Downstream-1.2.0.dmg")
        expectEqual(release.checksum?.name, "Downstream-1.2.0.dmg.sha256")
        expect(AppUpdater.isUpdate(release, over: "1.1.9"), "newer")
        expect(!AppUpdater.isUpdate(release, over: "1.2.0"), "same version isn't an update")
        expect(!AppUpdater.isUpdate(release, over: "2.0"), "older isn't an update")

        // A release without a .sha256 asset must leave checksum nil: installing then has nothing
        // to verify against and is refused (the updater fails closed).
        let noChecksumJSON = #"""
        {"tag_name": "v1.2.0", "name": "Downstream 1.2.0", "body": "Notes", "html_url": "https://github.com/scorpionTaj/Downstream/releases/tag/v1.2.0",
         "assets": [
           {"name": "Downstream-1.2.0.dmg", "browser_download_url": "https://example.com/a.dmg", "size": 2000000}],
         "extra": {"ignored": true}}
        """#
        let noChecksum = try JSONDecoder().decode(AppRelease.self, from: Data(noChecksumJSON.utf8))
        expectEqual(noChecksum.checksum, nil)
        expectEqual(noChecksum.diskImage?.name, "Downstream-1.2.0.dmg")
    }

    await suite("AppUpdater: a failed request reports the HTTP status") {
        // A local server that answers 404, so no network is involved.
        let server = try ProcessRunner.start(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import http.server; s = http.server.HTTPServer((\"127.0.0.1\", 0), http.server.SimpleHTTPRequestHandler); print(s.server_address[1], flush=True); s.serve_forever()"])
        defer { server.cancel() }
        var port: String?
        do { for try await line in server.lines { port = line.text; break } }
        guard let port, let portNumber = Int(port.trimmingCharacters(in: .whitespaces)), portNumber > 0 else {
            expect(false, "the local server didn't report a port"); return
        }
        let feed = URL(string: "http://127.0.0.1:\(portNumber)/missing.json")!
        do {
            _ = try await AppUpdater.latestRelease(feed: feed)
            expect(false, "a 404 feed must be refused")
        } catch let error as UpdateError {
            expectEqual(error, .requestFailed(status: 404))
        }
    }

    await suite("AppUpdater: checksum and install from a disk image") {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("downstream-update-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        // A tiny signed "Downstream.app" with a given version, packed into a disk image.
        func makeApp(at folder: URL, version: String, bundleID: String) async throws -> URL {
            let app = folder.appendingPathComponent("Downstream.app")
            try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                                        "CFBundleExecutable": "Downstream", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Downstream"))
            _ = try await ProcessRunner.output(of: URL(fileURLWithPath: "/usr/bin/codesign"),
                                               arguments: ["--force", "--sign", "-", app.path])
            return app
        }
        let source = work.appendingPathComponent("source")
        let installed = work.appendingPathComponent("Applications")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        _ = try await makeApp(at: source, version: "9.9.9", bundleID: "com.scorpiontaj.downstream")
        let oldApp = try await makeApp(at: installed, version: "1.0.0", bundleID: "com.scorpiontaj.downstream")
        let dmg = work.appendingPathComponent("Downstream-9.9.9.dmg")
        _ = try await ProcessRunner.output(of: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                           arguments: ["create", "-quiet", "-srcfolder", source.path, "-format", "UDZO", dmg.path],
                                           timeout: .seconds(120))

        let hash = try AppUpdater.sha256(of: dmg)
        try AppUpdater.verify(dmg, checksumFileContents: "\(hash.uppercased())  Downstream-9.9.9.dmg\n")
        do {
            try AppUpdater.verify(dmg, checksumFileContents: String(repeating: "0", count: 64))
            expect(false, "a wrong checksum must be rejected")
        } catch let error as UpdateError { expectEqual(error, .checksumMismatch) }

        do {
            try await AppUpdater.install(from: dmg, replacing: oldApp, bundleID: "com.example.other", trashOldVersion: false)
            expect(false, "a different app must be rejected")
        } catch let error as UpdateError { expectEqual(error, .wrongApp(bundleID: "com.scorpiontaj.downstream")) }
        expectEqual(Bundle(url: oldApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0.0")

        try await AppUpdater.install(from: dmg, replacing: oldApp, bundleID: "com.scorpiontaj.downstream", trashOldVersion: false)
        let version = NSDictionary(contentsOf: oldApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        expectEqual(version, "9.9.9")
        expectEqual(try fm.contentsOfDirectory(atPath: installed.path).filter { !$0.hasPrefix(".") }, ["Downstream.app"])
    }

    await suite("DownloadManager: hold, resume all, retry failed") {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let tools = DownloadTools(ytDlp: sh, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        let folder = FileManager.default.temporaryDirectory
        let manager = DownloadManager(starter: { _, _ in try ProcessRunner.start(sh, arguments: ["-c", "exit 1"]) })
        manager.isHeld = true
        let job = manager.add(url: URL(string: "https://example.com/h")!, options: DownloadOptions(), title: "h",
                              thumbnailURL: nil, outputDirectory: folder, tools: tools)
        try await Task.sleep(for: .milliseconds(200))
        expectEqual(job.state, .queued)   // held
        manager.isHeld = false
        for _ in 0..<300 where !job.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(manager.failedCount, 1)
        manager.retryFailed()
        expect(job.state == .queued || job.isRunning || job.isFinished, "retried")
        for _ in 0..<300 where !job.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        manager.pause(job)   // finished jobs ignore pause
        expectEqual(manager.pausedCount, 0)
    }
}

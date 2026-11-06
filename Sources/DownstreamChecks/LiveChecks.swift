import Foundation
@testable import DownstreamCore

/// Runs real downloads through the whole engine. Needs the network and Homebrew's yt-dlp and ffmpeg.
/// Run with: swift run DownstreamChecks --live
func liveChecks() async {
    let report = await ToolLocator().check()
    guard let ytDlp = report[.ytDlp]?.url, let ffmpeg = report[.ffmpeg]?.url else {
        print("• live checks skipped: yt-dlp or ffmpeg not found")
        return
    }
    // "Me at the zoo": 19 seconds, the first video on YouTube.
    let url = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-live-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = DownloadContext(url: url, outputDirectory: folder, ffmpeg: ffmpeg, aria2c: report[.aria2c]?.url)

    /// Runs a download and returns its events, printing a one-line summary.
    func download(_ options: DownloadOptions) async throws -> [ProgressEvent] {
        let running = try ProcessRunner.start(ytDlp, arguments: try ArgumentBuilder.downloadArguments(options, context: context))
        var events: [ProgressEvent] = []
        for try await line in running.lines { events.append(ProgressParser.parse(line)) }
        return events
    }

    func finalPath(_ events: [ProgressEvent]) -> String? {
        events.lazy.compactMap { if case .finalFile(let path) = $0 { path } else { nil } }.last
    }

    func probe(_ path: String, _ entries: String) async throws -> String {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        return try await ProcessRunner.output(of: ffprobe, arguments: ["-v", "error", "-show_entries", entries, "-of", "default=nw=1:nk=1", path])
    }

    await suite("live: metadata") {
        let info = try await MetadataFetcher(ytDlp: ytDlp).fetch(url)
        expectEqual(info.title, "Me at the zoo")
        expect(!info.formats.isEmpty, "formats listed")
        print("  · heights \(info.availableHeights), subtitles \(info.subtitleLanguages)")
    }

    await suite("live: bad URL gives yt-dlp's error") {
        do {
            _ = try await MetadataFetcher(ytDlp: ytDlp).fetch(URL(string: "https://www.youtube.com/watch?v=xxxxxxxxxxx")!)
            expect(false, "should fail")
        } catch let error as MetadataError {
            print("  · \(error)")
            if case .ytDlpFailed(let message) = error { expect(!message.isEmpty, "has a message") } else { expect(false, "ytDlpFailed expected") }
        }
    }

    await suite("live: audio to MP3") {
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .mp3
        let events = try await download(options)
        let path = finalPath(events)
        expect(path?.hasSuffix(".mp3") == true, "final file is an mp3: \(path ?? "none")")
        expect(path.map { FileManager.default.fileExists(atPath: $0) } == true, "file exists")
        expect(events.contains(.postprocessing(name: "ExtractAudio")), "audio was extracted")
        if let path {
            let duration = Double(try await probe(path, "format=duration")) ?? 0
            expect(abs(duration - 19) < 2, "about 19 seconds long (\(duration))")
        }
    }

    await suite("live: video, 240p MP4 with embedded English subtitles") {
        var options = DownloadOptions()
        options.maxHeight = 240
        options.subtitles = SubtitleOptions(languages: ["en"], embed: true)
        let events = try await download(options)
        let path = finalPath(events)
        expect(path?.hasSuffix(".mp4") == true, "final file is an mp4: \(path ?? "none")")
        let stepNames = events.compactMap { if case .postprocessing(let name) = $0 { name } else { nil } }
        print("  · steps: \(stepNames.joined(separator: ", "))")
        if let path {
            let streams = try await probe(path, "stream=codec_type")
            expect(streams.contains("video") && streams.contains("audio"), "has video and audio: \(streams)")
            expect(streams.contains("subtitle"), "has an embedded subtitle stream")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".vtt") } ?? []
            expectEqual(leftovers, [])
            let height = Int(try await probe(path, "stream=height").split(separator: "\n").first ?? "") ?? 0
            expect(height > 0 && height <= 240, "height at most 240 (\(height))")
        }
    }

    await suite("live: download through aria2") {
        guard context.aria2c != nil else { print("  · skipped: aria2c not installed"); return }
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .m4a
        options.aria2Connections = 4
        options.filenameTemplate = "aria2-%(id)s.%(ext)s"
        let events = try await download(options)
        let path = finalPath(events)
        expect(path.map { FileManager.default.fileExists(atPath: $0) } == true, "file exists: \(path ?? "none")")
        let updates = events.filter { if case .downloading = $0 { true } else { false } }.count
        print("  · \(updates) progress updates via aria2")
    }

    await suite("live: cancelling leaves no yt-dlp process behind") {
        var options = DownloadOptions()
        options.rateLimitKiB = 20   // slow enough to still be running when cancelled
        options.filenameTemplate = "cancel-%(id)s.%(ext)s"
        let running = try ProcessRunner.start(ytDlp, arguments: try ArgumentBuilder.downloadArguments(options, context: context))
        var result: Error?
        do {
            for try await line in running.lines {
                if case .downloading = ProgressParser.parse(line) { running.cancel() }
            }
        } catch { result = error }
        expectEqual(result as? ProcessError, .cancelled)
        let leftovers = try await ProcessRunner.output(of: URL(fileURLWithPath: "/bin/sh"),
                                                       arguments: ["-c", "pgrep -f 'cancel-%\\(id\\)s' || true"])
        expectEqual(leftovers, "")
    }

    await suite("live: a cancelled job deletes its partial files") {
        var options = DownloadOptions()
        options.rateLimitKiB = 200
        options.filenameTemplate = "jobcancel [%(id)s].%(ext)s"
        let jobContext = DownloadContext(url: url, outputDirectory: folder, ffmpeg: ffmpeg)
        let job = DownloadJob(url: url, options: options, context: jobContext, ytDlp: ytDlp)
        let run = Task { @MainActor in await job.run(starter: { try ProcessRunner.start($0, arguments: $1) }) }
        for _ in 0..<600 where (job.lastProgress?.downloadedBytes ?? 0) < 50_000 { try await Task.sleep(for: .milliseconds(50)) }
        let during = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix("jobcancel") } ?? []
        print("  · while downloading: \(during), progress file: \(job.lastProgress?.filename ?? "nil")")
        job.cancel()
        await run.value
        expectEqual(job.state, .cancelled)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix("jobcancel") } ?? []
        expectEqual(after, [])
    }

    await suite("live: update a 1.0.0 copy from the latest GitHub release") {
        let release = try await AppUpdater.latestRelease()
        print("  · latest release \(release.tagName), \(release.diskImage?.name ?? "no dmg")")
        expect(AppUpdater.isUpdate(release, over: "1.0.0"), "the latest release is newer than 1.0.0")
        guard let asset = release.diskImage, let checksum = release.checksum else { expect(false, "release has a dmg and checksum"); return }

        // A scratch "installed" copy that says it's 1.0.0.
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("downstream-live-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let installed = work.appendingPathComponent("Downstream.app")
        try fm.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.scorpiontaj.downstream", "CFBundleShortVersionString": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: installed.appendingPathComponent("Contents/Info.plist"))

        let (dmgData, _) = try await URLSession.shared.data(from: asset.downloadURL)
        let dmg = work.appendingPathComponent(asset.name)
        try dmgData.write(to: dmg)
        let (sumData, _) = try await URLSession.shared.data(from: checksum.downloadURL)
        try AppUpdater.verify(dmg, checksumFileContents: String(decoding: sumData, as: UTF8.self))

        try await AppUpdater.install(from: dmg, replacing: installed, bundleID: "com.scorpiontaj.downstream", trashOldVersion: false)
        let version = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        expectEqual(version, release.version?.description)
        let verify = try? await ProcessRunner.output(of: URL(fileURLWithPath: "/usr/bin/codesign"),
                                                     arguments: ["--verify", "--deep", installed.path])
        expect(verify != nil, "installed copy has a valid signature")
    }
}

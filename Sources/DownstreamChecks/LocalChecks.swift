import Foundation
@testable import DownstreamCore

/// The real thing, without the internet: real yt-dlp, ffmpeg and aria2 downloading from a small web server on
/// this Mac (`Fixtures/server.py`) that can refuse, stall and lose files on demand, into real folders and onto a
/// disk image that can fill up and be unplugged. Everything the scripted checks claim, seen to happen.
@MainActor
func localChecks() async {
    let report = await ToolLocator().check()
    guard let tools = DownloadTools(report: report) else {
        print("• local checks skipped: yt-dlp or ffmpeg not found")
        return
    }
    let sh = URL(fileURLWithPath: "/bin/sh")
    let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-local-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    // A real 20-second video, about a megabyte.
    let media = scratch.appendingPathComponent("media.mp4")
    do {
        _ = try await ProcessRunner.output(of: tools.ffmpeg, arguments: [
            "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25", "-f", "lavfi", "-i", "sine=frequency=440",
            "-t", "20", "-c:v", "libx264", "-b:v", "1500k", "-c:a", "aac", "-pix_fmt", "yuv420p", media.path])
    } catch {
        print("• local checks skipped: couldn't make the test video (\(error))")
        return
    }
    let mediaSize = (try? FileManager.default.attributesOfItem(atPath: media.path)[.size] as? NSNumber)?.int64Value ?? 0

    /// Starts the server (on `port`, or any free one) and returns it with the port it listens on.
    func startServer(port: Int = 0) async throws -> (process: RunningProcess, port: Int) {
        let process = try ProcessRunner.start(URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "python3", fixtures.appendingPathComponent("server.py").path, media.path, String(port)])
        for try await line in process.lines {
            if line.text.hasPrefix("PORT "), let port = Int(line.text.dropFirst(5)) { return (process, port) }
        }
        throw ProcessError.failed(exitCode: 1, stderrTail: ["the test server didn't start"])
    }
    guard let server = try? await startServer() else {
        print("• local checks skipped: couldn't start the test server (python3)")
        return
    }
    defer { server.process.cancel() }
    func link(_ path: String, port: Int? = nil) -> URL { URL(string: "http://127.0.0.1:\(port ?? server.port)/\(path)")! }

    func waitFor(_ seconds: Int, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 20) where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }
    func makeFolder(_ name: String) -> URL {
        let folder = scratch.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    func size(_ file: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
    }
    func videos(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".mp4") }.sorted()
    }
    /// Plain options: the server's file as it is, so its size can be compared.
    var plain = DownloadOptions()
    plain.embedMetadata = false
    plain.embedThumbnail = false
    plain.embedChapters = false
    func add(_ manager: DownloadManager, _ url: URL, to folder: URL, _ options: DownloadOptions? = nil) -> DownloadJob {
        manager.add(url: url, options: options ?? plain, title: nil, thumbnailURL: nil, outputDirectory: folder, tools: tools)
    }
    func saved(_ job: DownloadJob) -> URL? { if case .completed(let file) = job.state { file } else { nil } }
    func describe(_ job: DownloadJob) -> String { "\(job.state)\n    " + job.log.suffix(6).joined(separator: "\n    ") }

    await suite("local: a plain download, with real yt-dlp") {
        let manager = DownloadManager()
        let job = add(manager, link("v/plain.mp4"), to: makeFolder("plain"))
        try await waitFor(60) { job.isFinished }
        expect(saved(job) != nil, "completed, got \(describe(job))")
        expectEqual(saved(job).map(size), mediaSize)
        expectEqual(job.subtitleStatus, nil)
    }

    await suite("local: the site answers 429, then lets the download through") {
        let manager = DownloadManager()
        manager.retryPolicy = RetryPolicy(count: 2, firstWaitSeconds: 1)
        let job = add(manager, link("busy/1/busy.mp4"), to: makeFolder("busy"))
        try await waitFor(10) { job.automaticRetry == 1 }
        expectEqual(job.state, .queued)   // waiting for the retry, not failed
        expectEqual(manager.runningCount, 0)
        try await waitFor(60) { job.isFinished }
        expect(saved(job) != nil, "completed on the second try, got \(describe(job))")
        expect(job.log.contains { $0.contains("HTTP Error 429") }, "yt-dlp really was refused")
    }

    await suite("local: the site keeps answering 429") {
        let manager = DownloadManager()
        manager.retryPolicy = RetryPolicy(count: 1, firstWaitSeconds: 1)
        let job = add(manager, link("busy/99/never.mp4"), to: makeFolder("never"))
        try await waitFor(60) { job.isFinished }
        expectEqual(job.state, .failed("The site is refusing requests for now. Try again later."))
        expectEqual(job.log.filter { $0.contains("trying again") }.count, 1)
    }

    await suite("local: a download that stalls is restarted and finishes") {
        let manager = DownloadManager()
        let job = add(manager, link("stall/stalled.mp4"), to: makeFolder("stall"))
        job.stallLimit = .seconds(3)
        try await waitFor(90) { job.isFinished }
        expect(saved(job) != nil, "completed, got \(describe(job))")
        expect(job.log.contains { $0.contains("no progress") }, "Downstream restarted it")
        expectEqual(saved(job).map(size), mediaSize)   // carried on from what it had, and the file is whole
    }

    if tools.aria2c != nil {
        await suite("local: aria2 downloads, and a stalled aria2 download is restarted") {
            var options = plain
            options.aria2Connections = 4
            let manager = DownloadManager()
            let folder = makeFolder("aria2")
            let fine = add(manager, link("slow/aria.mp4"), to: folder, options)
            fine.stallLimit = .seconds(4)
            try await waitFor(90) { fine.isFinished }
            expect(saved(fine) != nil, "completed, got \(describe(fine))")
            expect(!fine.log.contains { $0.contains("no progress") }, "a slow aria2 download isn't taken for a stalled one")
            expectEqual(saved(fine).map(size), mediaSize)

            let stuck = add(manager, link("stall/aria-stuck.mp4"), to: folder, options)
            stuck.stallLimit = .seconds(4)
            try await waitFor(120) { stuck.isFinished }
            expect(saved(stuck) != nil, "completed, got \(describe(stuck))")
            expect(stuck.log.contains { $0.contains("no progress") }, "Downstream noticed without any output from aria2")
            expectEqual(saved(stuck).map(size), mediaSize)
        }
    }

    await suite("local: after waking up, a running download starts again and finishes") {
        let manager = DownloadManager()
        let job = add(manager, link("slow/wake.mp4"), to: makeFolder("wake"))
        try await waitFor(30) { (job.lastProgress?.downloadedBytes ?? 0) > 200_000 }
        manager.restartAfterWake()
        try await waitFor(90) { job.isFinished }
        expect(saved(job) != nil, "completed, got \(describe(job))")
        expect(job.log.contains { $0.contains("woke up") }, "it was restarted")
        expectEqual(saved(job).map(size), mediaSize)
        expectEqual(job.automaticRetry, nil)
    }

    await suite("local: no network — the download waits, then runs when it's back") {
        // A port nothing listens on yet: the "site" is unreachable until the server starts there.
        let reserved = try await startServer()
        reserved.process.cancel()
        try await Task.sleep(for: .milliseconds(500))
        let manager = DownloadManager()
        manager.retryPolicy = RetryPolicy(count: 0, firstWaitSeconds: 5)
        manager.isOnline = false
        let job = add(manager, link("v/offline.mp4", port: reserved.port), to: makeFolder("offline"))
        try await waitFor(30) { job.waitingForNetwork }
        expectEqual(DownloadFormatting.status(of: job), "Waiting for the network…")
        expectEqual(manager.runningCount, 0)

        let back = try await startServer(port: reserved.port)
        defer { back.process.cancel() }
        manager.isOnline = true
        try await waitFor(60) { job.isFinished }
        expect(saved(job) != nil, "completed once the network was back, got \(describe(job))")
    }

    await suite("local: a playlist with a missing item, then retrying only that item") {
        var options = plain
        options.downloadPlaylist = true
        let manager = DownloadManager()
        let folder = makeFolder("playlist")
        let library = Library(directory: makeFolder("playlist-library"))
        manager.onJobFinished = { library.record($0) }
        let job = add(manager, link("feed.xml"), to: folder, options)
        try await waitFor(90) { job.isFinished }
        expect(saved(job) != nil, "completed, got \(describe(job))")
        expectEqual(job.failedItems, 1)
        expectEqual(job.playlistTotal, 3)
        expect(DownloadFormatting.status(of: job).hasPrefix("2 of 3 saved"), "got \(DownloadFormatting.status(of: job))")
        expectEqual(videos(in: folder).count, 2)
        expectEqual(library.history.count, 3)   // two files and the note about the third
        expectEqual(library.history.first?.failure, "1 of 3 items couldn't be downloaded.")

        // The missing video appears; retry fetches it and leaves the other two alone.
        _ = try await ProcessRunner.output(of: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["-s", link("heal").absoluteString])
        let before = videos(in: folder).map { (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.modificationDate] as? Date) ?? .distantPast }
        manager.retry(job)
        try await waitFor(90) { job.isFinished && job.failedItems == 0 }
        expect(DownloadFormatting.status(of: job).hasPrefix("3 files"), "got \(DownloadFormatting.status(of: job))\n    \(describe(job))")
        expectEqual(videos(in: folder).count, 3)
        expect(job.log.contains { $0.contains("already been recorded in the archive") } || !job.log.contains { $0.contains("[a]") },
               "the two saved items weren't fetched again")
        let after = videos(in: folder).prefix(1).map { (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.modificationDate] as? Date) ?? .distantPast }
        expectEqual(after.first, before.first)   // a's file wasn't rewritten
        expectEqual(library.history.count, 4)    // only the new file was added
    }

    await suite("local: a yt-dlp left behind by a crash is found and stopped") {
        let folder = makeFolder("orphan")
        let context = DownloadContext(url: link("slow/orphan.mp4"), outputDirectory: folder, ffmpeg: tools.ffmpeg)
        let arguments = try ArgumentBuilder.downloadArguments(plain, context: context)
        let quoted = ([tools.ytDlp.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // Its parent (this sh) exits at once, as a crashed Downstream would have.
        _ = try await ProcessRunner.output(of: sh, arguments: ["-c", quoted + " >/dev/null 2>&1 &"])
        let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
        func orphans() async -> Int {
            ((try? await ProcessRunner.output(of: pgrep, arguments: ["-P", "1", "-f", "download:@@P "])) ?? "").split(separator: "\n").count
        }
        for _ in 0..<50 where await orphans() == 0 { try await Task.sleep(for: .milliseconds(100)) }
        expect(await orphans() >= 1, "the orphaned yt-dlp is running")
        await OrphanedDownloads.stop(gracePeriod: .seconds(2))
        expectEqual(await orphans(), 0)
    }

    // A real volume: 24 MB, mounted under /Volumes like an external drive.
    let image = scratch.appendingPathComponent("drive.dmg")
    let volumeName = "Downstream-\(UUID().uuidString.prefix(8))"
    let volume = URL(fileURLWithPath: "/Volumes/\(volumeName)")
    func attach() async throws { _ = try await ProcessRunner.output(of: hdiutil, arguments: ["attach", image.path, "-nobrowse", "-quiet"]) }
    func detach() async { _ = try? await ProcessRunner.output(of: hdiutil, arguments: ["detach", volume.path, "-force", "-quiet"]) }
    do {
        _ = try await ProcessRunner.output(of: hdiutil, arguments: ["create", "-size", "24m", "-fs", "HFS+", "-volname", volumeName, "-quiet", image.path])
        try await attach()
    } catch {
        print("• local: disk image checks skipped: couldn't create or mount one (\(error))")
        return
    }

    await suite("local: a disk without room pauses the download; freeing space lets it finish") {
        let manager = DownloadManager()
        let folder = volume.appendingPathComponent("Videos")
        // 24 MB is under the floor a download needs to start.
        let small = add(manager, link("v/small.mp4"), to: folder)
        try await waitFor(20) { small.state == .paused }
        expectEqual(small.pauseReason, .diskFull)
        expectEqual(DownloadFormatting.status(of: small), "Paused · not enough disk space")
        manager.remove(small)

        // Room to start, but not for the whole file: stopped when yt-dlp reports the size.
        let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
        let filler = volume.appendingPathComponent("filler")
        FileManager.default.createFile(atPath: filler.path, contents: Data(count: max(0, free - 500_000)))
        let job = add(manager, link("slow/tight.mp4"), to: folder)
        job.minimumFreeBytes = 0
        try await waitFor(30) { job.state == .paused }
        expectEqual(job.pauseReason, .diskFull)
        expect(job.log.contains { $0.contains("not enough disk space") }, "got \(describe(job))")

        try FileManager.default.removeItem(at: filler)
        manager.resume(job)
        try await waitFor(90) { job.isFinished }
        expect(saved(job) != nil, "completed after space was freed, got \(describe(job))")
        expectEqual(saved(job).map(size), mediaSize)
    }

    await suite("local: unplugging the drive pauses the download; plugging it back lets it finish") {
        let manager = DownloadManager()
        let job = add(manager, link("slow/drive.mp4"), to: volume.appendingPathComponent("Videos"))
        job.minimumFreeBytes = 0
        try await waitFor(30) { (job.lastProgress?.downloadedBytes ?? 0) > 200_000 }
        await detach()
        try await waitFor(60) { job.state == .paused }
        expectEqual(job.pauseReason, .folderUnavailable)
        expectEqual(DownloadFormatting.status(of: job), "Paused · the download folder isn't available")

        manager.resume(job)   // still unplugged: pauses again rather than failing
        try await waitFor(20) { job.state == .paused && job.pauseReason == .folderUnavailable }
        expectEqual(job.state, .paused)

        try await attach()
        manager.resume(job)
        try await waitFor(90) { job.isFinished }
        expect(saved(job) != nil, "completed once the drive was back, got \(describe(job))")
        expectEqual(saved(job).map(size), mediaSize)
    }
    await detach()
}

import Foundation
@testable import DownstreamCore

/// Drives `DownloadJob` and `DownloadManager` with shell scripts standing in for yt-dlp.
@MainActor
func downloadJobChecks() async {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    let fixturePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/progress-audio.txt").path

    func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func makeJob(_ options: DownloadOptions = DownloadOptions(), folder: URL = FileManager.default.temporaryDirectory) -> DownloadJob {
        let context = DownloadContext(url: URL(string: "https://example.com/v")!, outputDirectory: folder, ffmpeg: ffmpeg)
        return DownloadJob(url: context.url, options: options, context: context, ytDlp: sh)
    }

    func script(_ body: String) -> ProcessStarter {
        { _, _ in try ProcessRunner.start(sh, arguments: ["-c", body]) }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    func progressLine(_ file: String, _ done: Int = 10) -> String {
        #"@@P {"status": "downloading", "downloaded_bytes": \#(done), "total_bytes": 100, "speed": 5.0, "eta": 18, "filename": "\#(file)"}"#
    }

    await suite("DownloadJob: replayed audio download completes") {
        let job = makeJob()
        await job.run(starter: script("cat '\(fixturePath)'"))
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/dl/Me at the zoo.mp3")))
        expectEqual(job.savedFiles.count, 1)
        expect(job.isFinished && !job.isRunning, "finished, not running")
        expect(job.log.contains { $0.contains("ExtractAudio") }, "postprocessing lines logged")
        expect(!job.log.contains { $0.hasPrefix("@@P") }, "progress lines not logged")
        expectEqual(DownloadFormatting.status(of: job), "MP3")   // the file doesn't exist here, so no size
    }

    await suite("DownloadJob: yt-dlp error becomes the failure message, retry starts over") {
        let job = makeJob()
        await job.run(starter: script("echo 'WARNING: meh' >&2; echo 'ERROR: [youtube] abc: Video unavailable' >&2; exit 1"))
        expectEqual(job.state, .failed("[youtube] abc: Video unavailable"))
        expect(job.canRetry, "failed jobs can be retried")
        expect(!job.log.isEmpty, "error is in the log")
        job.retry()
        expectEqual(job.state, .queued)
        expectEqual(job.log, [])
        await job.run(starter: script("echo '@@F /tmp/ok.mp4'"))
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
    }

    await suite("DownloadJob: success without a file is a failure") {
        let job = makeJob()
        await job.run(starter: script("echo hello"))
        expectEqual(job.state, .failed("yt-dlp finished without saving a file."))
    }

    await suite("DownloadJob: invalid options fail before starting") {
        var options = DownloadOptions()
        options.filenameTemplate = "/etc/x"
        let job = makeJob(options)
        await job.run(starter: script("exit 0"))
        if case .failed(let message) = job.state { expect(message.contains("inside the download folder"), message) } else { expect(false, "should fail") }
    }

    await suite("DownloadJob: cancel deletes this download's partial files only") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fm = FileManager.default
        // Files from before the download started, which must survive.
        let old = folder.appendingPathComponent("Clip [abc].old-notes.txt").path
        fm.createFile(atPath: old, contents: Data())
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old)
        fm.createFile(atPath: folder.appendingPathComponent("Other [xyz].mp4").path, contents: Data())

        let part = folder.appendingPathComponent("Clip [abc].f401.mp4").path
        let job = makeJob(folder: folder)
        let body = """
            touch '\(part).part' '\(folder.path)/Clip [abc].webp' '\(folder.path)/Clip [abc].f251.webm.part-Frag2'
            echo '\(progressLine(part))'; exec sleep 30
            """
        let run = Task { @MainActor in await job.run(starter: script(body)) }
        try await waitUntil { job.lastProgress != nil }
        expectEqual(DownloadFormatting.status(of: job), "10 bytes of 100 bytes · 5 bytes/s · 18 s left")
        job.cancel()
        await run.value
        expectEqual(job.state, .cancelled)
        let left = try fm.contentsOfDirectory(atPath: folder.path).sorted()
        expectEqual(left, ["Clip [abc].old-notes.txt", "Other [xyz].mp4"])
    }

    await suite("DownloadJob: cancel during post-processing deletes the merged file too") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("Film [id1].f400.mp4").path
        let audio = folder.appendingPathComponent("Film [id1].f251.webm").path
        let merged = folder.appendingPathComponent("Film [id1].mp4").path
        let job = makeJob(folder: folder)
        let body = """
            touch '\(video)' '\(audio)' '\(folder.path)/Film [id1].jpg'
            echo '\(progressLine(video, 100))'
            echo '@@P {"status": "finished", "filename": "\(audio)"}'
            echo '@@Q {"status": "started", "postprocessor": "Merger"}' >&2
            touch '\(merged)'; exec sleep 30
            """
        let run = Task { @MainActor in await job.run(starter: script(body)) }
        try await waitUntil { if case .processing = job.state { true } else { false } }
        try await Task.sleep(for: .milliseconds(100))
        job.cancel()
        await run.value
        expectEqual(job.state, .cancelled)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        print("  · \(job.log.last ?? "")")
    }

    await suite("PartialFiles: folder reached through a symlink (/tmp → /private/tmp)") {
        let name = "downstream-symlink-\(UUID().uuidString)"
        let real = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        FileManager.default.createFile(atPath: real.path + "/Clip [s1].f401.mp4.part", contents: Data())
        // yt-dlp reports the path as given; the folder URL may be spelled either way.
        for folder in [real, URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)] {
            FileManager.default.createFile(atPath: real.path + "/Clip [s1].f401.mp4.part", contents: Data())
            let removed = PartialFiles.remove(writtenBy: ["/private/tmp/\(name)/Clip [s1].f401.mp4"], in: folder,
                                              since: Date(timeIntervalSinceNow: -60), keeping: [])
            expectEqual(removed, ["Clip [s1].f401.mp4.part"])
        }
    }

    await suite("DownloadJob: a cancel that arrives as yt-dlp finishes leaves it completed") {
        let job = makeJob()
        // Ignores SIGINT and exits 0 after saving, like yt-dlp already in its last step.
        let run = Task { @MainActor in
            await job.run(starter: script("trap '' INT; echo '\(progressLine("/tmp/late.mp4"))'; sleep 0.5; echo '@@F /tmp/late.mp4'"))
        }
        try await waitUntil { job.lastProgress != nil }
        job.cancel()
        await run.value
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/late.mp4")))
    }

    await suite("DownloadJob: pause keeps partial files, resume continues") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let part = folder.appendingPathComponent("Clip [abc].mp4").path
        let job = makeJob(folder: folder)
        let run = Task { @MainActor in await job.run(starter: script("touch '\(part).part'; echo '\(progressLine(part, 40))'; exec sleep 30")) }
        try await waitUntil { job.lastProgress != nil }
        expect(job.canPause, "a downloading job can pause")
        job.pause()
        await run.value
        expectEqual(job.state, .paused)
        expectEqual(DownloadFormatting.status(of: job), "Paused · 40 bytes of 100 bytes")
        expect(FileManager.default.fileExists(atPath: part + ".part"), ".part kept for resuming")
        job.resume()
        expectEqual(job.state, .queued)
        await job.run(starter: script("mv '\(part).part' '\(part)'; echo '@@F \(part)'"))
        expectEqual(job.state, .completed(URL(fileURLWithPath: part)))
    }

    await suite("DownloadJob: queued jobs pause, resume and cancel without running") {
        let job = makeJob()
        job.pause()
        expectEqual(job.state, .paused)
        job.resume()
        expectEqual(job.state, .queued)
        job.cancel()
        expectEqual(job.state, .cancelled)
        await job.run(starter: script("echo '@@F /tmp/x.mp4'"))
        expectEqual(job.state, .cancelled)   // a cancelled job never starts on its own
        expect(job.canRetry, "cancelled jobs can be retried")
    }

    await suite("DownloadManager: unfinishedJob finds the duplicate link") {
        let folder = makeFolder()
        let otherFolder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: otherFolder) }
        let manager = DownloadManager()
        manager.isHeld = true   // nothing runs; the added job stays queued
        let url = URL(string: "https://example.com/dup")!
        let job = manager.add(url: url, options: DownloadOptions(), title: "dup", thumbnailURL: nil,
                              outputDirectory: folder, tools: DownloadTools(ytDlp: sh, ffmpeg: ffmpeg))
        expectEqual(manager.unfinishedJob(url: url, outputDirectory: folder)?.id, job.id)
        expect(manager.unfinishedJob(url: url, outputDirectory: otherFolder) == nil, "another folder doesn't clash")
        expect(manager.unfinishedJob(url: URL(string: "https://example.com/other")!, outputDirectory: folder) == nil, "another link doesn't clash")
        job.cancel()   // queued → cancelled: finished, so the link is free again
        expect(manager.unfinishedJob(url: url, outputDirectory: folder) == nil, "a finished job isn't a duplicate")
    }

    await suite("DownloadManager: never more than maxConcurrent, oldest first") {
        var order: [String] = []
        let manager = DownloadManager(maxConcurrent: 2, starter: script("sleep 0.3; echo '@@F /tmp/x.mp4'"))
        manager.onJobFinished = { order.append($0.title) }
        let tools = DownloadTools(ytDlp: sh, ffmpeg: ffmpeg)
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a", "b", "c", "d", "e"] {
            manager.add(url: URL(string: "https://example.com/\(name)")!, options: DownloadOptions(), title: name,
                        thumbnailURL: nil, outputDirectory: folder, tools: tools)
        }
        expectEqual(manager.jobs.map(\.title), ["e", "d", "c", "b", "a"])
        var peak = 0
        for _ in 0..<500 where manager.unfinishedCount > 0 {
            peak = max(peak, manager.runningCount, manager.jobs.filter(\.isRunning).count)
            try await Task.sleep(for: .milliseconds(10))
        }
        expectEqual(peak, 2)
        expectEqual(manager.unfinishedCount, 0)
        expectEqual(order.count, 5)
        expectEqual(Array(order.prefix(2)).sorted(), ["a", "b"])   // the oldest two start first
        manager.removeFinished()
        expectEqual(manager.jobs.count, 0)
    }

    await suite("DownloadManager: raising the limit starts queued jobs, removing a paused one cancels it") {
        let manager = DownloadManager(maxConcurrent: 1, starter: script("exec sleep 30"))
        let tools = DownloadTools(ytDlp: sh, ffmpeg: ffmpeg)
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = manager.add(url: URL(string: "https://example.com/1")!, options: DownloadOptions(), title: "1",
                                thumbnailURL: nil, outputDirectory: folder, tools: tools)
        let second = manager.add(url: URL(string: "https://example.com/2")!, options: DownloadOptions(), title: "2",
                                 thumbnailURL: nil, outputDirectory: folder, tools: tools)
        try await waitUntil { first.isRunning }
        expectEqual(second.state, .queued)
        manager.maxConcurrent = 2
        try await waitUntil { second.isRunning }
        expect(second.isRunning, "second starts once the limit is raised")
        manager.remove(first)
        expectEqual(manager.jobs.count, 2)   // running jobs can't be removed
        manager.pause(first)
        try await waitUntil { first.state == .paused }
        manager.remove(first)
        expectEqual(first.state, .cancelled)
        expectEqual(manager.jobs.map(\.title), ["2"])
        manager.cancelAll()
        try await waitUntil { second.state == .cancelled }
        expectEqual(second.state, .cancelled)
        expectEqual(manager.unfinishedCount, 0)
    }

    await suite("PartialFiles.baseName") {
        expectEqual(PartialFiles.baseName(of: "Clip [abc].f401.mp4"), "Clip [abc]")
        expectEqual(PartialFiles.baseName(of: "Clip [abc].f251-drc.webm"), "Clip [abc]")
        expectEqual(PartialFiles.baseName(of: "Clip [abc].mp4"), "Clip [abc]")
        expectEqual(PartialFiles.baseName(of: "Mr. Fox [abc].mp4"), "Mr. Fox [abc]")
    }

    await suite("PartialFiles: only yt-dlp artifacts are deleted") {
        expect(PartialFiles.isArtifact("Title [id].mp4.part-Frag2"), "fragment partials count")
        expect(PartialFiles.isArtifact("Title [id].info.json"), "info json counts")
        expect(!PartialFiles.isArtifact("Title [id].json"), "a plain .json could be the user's")
        expect(!PartialFiles.isArtifact("Title [id].nfo"), "media library metadata isn't an artifact")

        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func touch(_ name: String) { try? Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        for name in ["Title [id].mp4.part", "Title [id].info.json", "Title [id].f140.m4a",
                     "Title [id].nfo", "Title [id].txt", "Title [id].json"] { touch(name) }
        let removed = PartialFiles.remove(writtenBy: [folder.appendingPathComponent("Title [id].mp4").path],
                                          in: folder, since: now.addingTimeInterval(-5), keeping: [])
        expectEqual(removed, ["Title [id].f140.m4a", "Title [id].info.json", "Title [id].mp4.part"])
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Title [id].nfo").path), "the user's .nfo survives")
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Title [id].txt").path), "the user's .txt survives")
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Title [id].json").path), "the user's .json survives")
    }

    await suite("DownloadFormatting") {
        expectEqual(DownloadFormatting.timeLeft(4.4), "4 s left")
        expectEqual(DownloadFormatting.timeLeft(125), "2 min left")
        expectEqual(DownloadFormatting.timeLeft(3900), "1 hr 5 min left")
        expectEqual(DownloadFormatting.timeLeft(7200), "2 hr left")
        expectEqual(DownloadFormatting.duration(19), "0:19")
        expectEqual(DownloadFormatting.duration(3723), "1:02:03")
        expectEqual(DownloadFormatting.status(of: makeJob()), "Queued")
    }
}

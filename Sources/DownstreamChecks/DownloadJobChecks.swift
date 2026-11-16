import Foundation
@testable import DownstreamCore

/// Something a callback switches on.
@MainActor private final class Flag { var on = false }

/// The arguments a stand-in yt-dlp was started with.
private final class Seen: @unchecked Sendable { var arguments: [String] = [] }

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

    /// Runs a job the way the manager does, minus the slots: again each time it's due, until it's no longer queued.
    func drive(_ job: DownloadJob, _ starter: @escaping ProcessStarter) async throws {
        while job.state == .queued {
            try await waitUntil { job.isReadyToRun }
            await job.run(starter: starter)
        }
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
        expectEqual(job.state, .failed("This video is unavailable or private."))
        expect(job.log.contains { $0.contains("[youtube] abc: Video unavailable") }, "yt-dlp's own words stay in the log")
        expect(job.canRetry, "failed jobs can be retried")
        expect(!job.log.isEmpty, "error is in the log")
        job.retry()
        expectEqual(job.state, .queued)
        expectEqual(job.log, [])
        await job.run(starter: script("echo '@@F /tmp/ok.mp4'"))
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
    }

    await suite("DownloadJob: refused subtitles don't fail the download, and are mentioned") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Real one-second videos, so ffmpeg has something to put the subtitles into.
        func makeClip(_ name: String) async throws -> URL {
            let clip = folder.appendingPathComponent(name)
            _ = try await ProcessRunner.output(of: ffmpeg, arguments: [
                "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=10", "-t", "1", "-pix_fmt", "yuv420p", clip.path])
            return clip
        }
        @Sendable func refused(_ file: String) -> String {
            "echo \"WARNING: Unable to download video subtitles for 'ar': HTTP Error 429: Too Many Requests\" >&2; sleep 0.3; echo '@@U https://example.com/item'; echo '@@F \(file)'"
        }
        /// yt-dlp for the download, then for each later subtitle try: `later` gets the folder it must write into.
        func starter(_ file: String, later: @escaping @Sendable (String) -> String) -> ProcessStarter {
            { _, arguments in
                guard arguments.contains("--skip-download") else { return try ProcessRunner.start(sh, arguments: ["-c", refused(file)]) }
                let scratch = arguments[arguments.firstIndex(of: "--paths")! + 1]
                expect(arguments.contains("ar") && arguments.last == "https://example.com/item", "asks for the refused language of that video")
                return try ProcessRunner.start(sh, arguments: ["-c", later(scratch)])
            }
        }
        let gotThem: @Sendable (String) -> String = { "printf 'WEBVTT\\n\\n00:00.000 --> 00:01.000\\nhello\\n' > '\($0)/subtitles.ar.vtt'" }
        @MainActor func recover(_ job: DownloadJob, _ starter: @escaping ProcessStarter) async throws {
            let done = Flag()
            job.recoverSubtitles(starter: starter) { done.on = true }
            expectEqual(DownloadFormatting.status(of: job).hasSuffix("Getting subtitles…"), true)
            try await waitUntil { done.on }
        }

        for name in ["clip.mp4", "clip.mkv"] {
            let clip = try await makeClip(name)
            let run = starter(clip.path, later: gotThem)
            let job = makeJob(folder: folder)
            job.subtitleRetryDelays = [.zero]
            await job.run(starter: run)
            expectEqual(job.state, .completed(clip))   // complete straight away, without them
            expectEqual(job.subtitleStatus, .missing)
            expect(DownloadFormatting.status(of: job).hasSuffix("Subtitles unavailable"), "says so")
            expect(job.owesSubtitles(for: clip), "history is told too")

            try await recover(job, run)
            expectEqual(job.subtitleStatus, nil)   // inside the video now
            expect(!job.owesSubtitles(for: clip), "nothing owed any more")
            let embedded = try await ProcessRunner.output(of: ffmpeg, arguments: ["-v", "error", "-i", clip.path, "-map", "0:s:0", "-f", "srt", "-"])
            expect(embedded.contains("hello"), "\(name) has the subtitle stream, got \(embedded)")
            expectEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.contains("temp") }, [])
        }

        // A file ffmpeg can't add them to: they go next to it.
        let odd = folder.appendingPathComponent("odd.mp4")
        FileManager.default.createFile(atPath: odd.path, contents: Data("not a video".utf8))
        let beside = makeJob(folder: folder)
        beside.subtitleRetryDelays = [.zero]
        await beside.run(starter: starter(odd.path, later: gotThem))
        try await recover(beside, starter(odd.path, later: gotThem))
        expectEqual(beside.subtitleStatus, .separate)
        expectEqual(DownloadFormatting.status(of: beside), "MP4 · 11 bytes · Subtitles in a separate file")
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("odd.ar.vtt").path), "odd.ar.vtt next to the video")
        expectEqual(try Data(contentsOf: odd), Data("not a video".utf8))   // untouched

        // Refused every time: still missing after the last try.
        let unlucky = makeJob(folder: folder)
        unlucky.subtitleRetryDelays = [.zero, .zero]
        let never = starter(odd.path) { _ in "echo 'ERROR: Unable to download video subtitles' >&2; exit 1" }
        await unlucky.run(starter: never)
        try await recover(unlucky, never)
        expectEqual(unlucky.subtitleStatus, .missing)
        expectEqual(unlucky.log.filter { $0.hasPrefix("ERROR: Unable to download video subtitles") }.count, 2)
    }

    await suite("SubtitleEmbedder: ffmpeg arguments") {
        let video = URL(fileURLWithPath: "/tmp/v.mp4")
        let tracks = [SubtitleEmbedder.Track(file: URL(fileURLWithPath: "/tmp/s.ar.vtt"), language: "ar"),
                      SubtitleEmbedder.Track(file: URL(fileURLWithPath: "/tmp/s.pt-BR.vtt"), language: "pt-BR")]
        let args = SubtitleEmbedder.arguments(video: video, tracks: tracks, output: URL(fileURLWithPath: "/tmp/o.mp4"))!
        expectEqual(args.joined(separator: " "),
                    "-y -loglevel error -i /tmp/v.mp4 -i /tmp/s.ar.vtt -i /tmp/s.pt-BR.vtt -map 0:v? -map 0:a? -map 1:0 -map 2:0 "
                    + "-map 0:s? -map 0:t? -c copy -c:s mov_text -metadata:s:s:0 language=ara -metadata:s:s:1 language=por /tmp/o.mp4")
        expectEqual(SubtitleEmbedder.codec(forContainer: "webm"), "webvtt")
        expectEqual(SubtitleEmbedder.codec(forContainer: "mkv"), "copy")
        expect(SubtitleEmbedder.arguments(video: URL(fileURLWithPath: "/tmp/v.mp3"), tracks: tracks, output: video) == nil, "no subtitles in an MP3")
    }

    await suite("RetryPolicy: waits grow five-fold up to ten minutes") {
        expectEqual(RetryPolicy(count: 5, firstWaitSeconds: 5).delays, [.seconds(5), .seconds(25), .seconds(125), .seconds(600), .seconds(600)])
        expectEqual(RetryPolicy(count: 2, firstWaitSeconds: 60).delays, [.seconds(60), .seconds(300)])
        expectEqual(RetryPolicy(count: 0, firstWaitSeconds: 5).delays, [])
        expectEqual(RetryPolicy(count: 99, firstWaitSeconds: 5).count, 10)
        expectEqual(RetryPolicy.default.delays.count, 3)
    }

    await suite("DownloadJob: a temporary failure is retried by itself") {
        expect(DownloadJob.isTemporary("Unable to download webpage: HTTP Error 429: Too Many Requests"), "429 is temporary")
        expect(DownloadJob.isTemporary("<urlopen error [Errno 8] nodename nor servname provided, or not known>"), "no network is temporary")
        expect(!DownloadJob.isTemporary("[youtube] abc: Video unavailable"), "an unavailable video isn't")
        expect(!DownloadJob.isTemporary("[youtube] abc: Sign in to confirm you're not a bot"), "a sign-in wall isn't")

        // Fails with a 503 until its marker file exists, so the second run succeeds.
        let marker = makeFolder().appendingPathComponent("tried").path
        let flaky = script("if [ -e '\(marker)' ]; then echo '@@F /tmp/ok.mp4'; else touch '\(marker)'; echo 'ERROR: HTTP Error 503: Service Unavailable' >&2; exit 1; fi")
        let job = makeJob()
        job.retryDelays = [.milliseconds(300)]
        await job.run(starter: flaky)
        expectEqual(job.state, .queued)   // waiting, without yt-dlp and without a slot
        expect(!job.isReadyToRun && !job.isRunning, "not ready until the wait is over")
        expectEqual(DownloadFormatting.status(of: job), "Trying again (1 of 1)…")
        try await drive(job, flaky)
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
        expect(job.log.contains { $0.contains("trying again (1 of 1)") }, "the retry is in the log")
        expectEqual(job.automaticRetry, nil)

        let failing = script("echo 'ERROR: HTTP Error 429: Too Many Requests' >&2; exit 1")
        let hopeless = makeJob()
        hopeless.retryDelays = [.milliseconds(10), .milliseconds(10)]
        try await drive(hopeless, failing)
        expectEqual(hopeless.state, .failed("The site is refusing requests for now. Try again later."))
        expectEqual(hopeless.log.filter { $0.contains("trying again") }.count, 2)
        hopeless.retry()   // the user's own retry gets the automatic ones afresh
        try await drive(hopeless, failing)
        expectEqual(hopeless.log.filter { $0.contains("trying again") }.count, 2)

        let permanent = makeJob()
        permanent.retryDelays = [.seconds(30)]
        await permanent.run(starter: script("echo 'ERROR: Video unavailable' >&2; exit 1"))
        expectEqual(permanent.state, .failed("This video is unavailable or private."))   // straight away: no 30 s wait
    }

    await suite("DownloadJob: pausing or cancelling while waiting to retry") {
        let failing = script("echo 'ERROR: HTTP Error 429: Too Many Requests' >&2; exit 1")
        for (stop, expected) in [(false, DownloadJob.State.paused), (true, .cancelled)] {
            let job = makeJob()
            job.retryDelays = [.seconds(30)]
            await job.run(starter: failing)
            expectEqual(job.automaticRetry, 1)
            if stop { job.cancel() } else { job.pause() }
            expectEqual(job.state, expected)
            expectEqual(job.automaticRetry, nil)
        }
        let resumed = makeJob()
        resumed.retryDelays = [.seconds(30)]
        await resumed.run(starter: failing)
        resumed.pause()
        resumed.resume()
        expect(resumed.isReadyToRun, "resuming doesn't wait out the rest of the delay")
    }

    await suite("DownloadManager: a download waiting to retry doesn't hold a slot") {
        let manager = DownloadManager(maxConcurrent: 1, starter: { _, arguments in
            let bad = arguments.last!.hasSuffix("/bad")
            return try ProcessRunner.start(sh, arguments: ["-c", bad ? "echo 'ERROR: HTTP Error 429: Too Many Requests' >&2; exit 1" : "sleep 0.2; echo '@@F /tmp/good.mp4'"])
        })
        manager.retryPolicy = RetryPolicy(count: 1, firstWaitSeconds: 1)
        var finished: [String] = []
        manager.onJobFinished = { finished.append($0.title) }
        let folder = FileManager.default.temporaryDirectory
        let bad = manager.add(url: URL(string: "https://example.com/bad")!, options: DownloadOptions(), title: "bad",
                              thumbnailURL: nil, outputDirectory: folder, tools: DownloadTools(ytDlp: sh, ffmpeg: ffmpeg))
        let good = manager.add(url: URL(string: "https://example.com/good")!, options: DownloadOptions(), title: "good",
                               thumbnailURL: nil, outputDirectory: folder, tools: DownloadTools(ytDlp: sh, ffmpeg: ffmpeg))
        try await waitUntil { good.isFinished }
        expectEqual(good.state, .completed(URL(fileURLWithPath: "/tmp/good.mp4")))   // ran while the first one waited
        expectEqual(bad.state, .queued)
        expectEqual(bad.automaticRetry, 1)
        expectEqual(manager.runningCount, 0)
        try await waitUntil { bad.isFinished }   // the manager comes back for it by itself when the wait is over
        expectEqual(bad.state, .failed("The site is refusing requests for now. Try again later."))
        expectEqual(finished, ["good", "bad"])   // waiting isn't finishing: no "failed" until it gives up
    }

    await suite("DownloadManager: offline, a failure waits for the network instead of failing") {
        let marker = makeFolder().appendingPathComponent("tried").path
        let manager = DownloadManager(maxConcurrent: 1, starter: script(
            "if [ -e '\(marker)' ]; then echo '@@F /tmp/ok.mp4'; else touch '\(marker)'; echo 'ERROR: something odd' >&2; exit 1; fi"))
        manager.retryPolicy = RetryPolicy(count: 0, firstWaitSeconds: 5)   // not a retry: waiting doesn't use any up
        manager.isOnline = false
        let job = manager.add(url: URL(string: "https://example.com/v")!, options: DownloadOptions(), title: nil, thumbnailURL: nil,
                              outputDirectory: FileManager.default.temporaryDirectory, tools: DownloadTools(ytDlp: sh, ffmpeg: ffmpeg))
        try await waitUntil { job.waitingForNetwork }
        expectEqual(job.state, .queued)
        expectEqual(DownloadFormatting.status(of: job), "Waiting for the network…")
        try await Task.sleep(for: .milliseconds(100))
        expectEqual(manager.runningCount, 0)   // no slot held, Mac free to sleep
        manager.isOnline = true
        try await waitUntil { job.isFinished }
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))

        // Should the system be wrong about the network, a waiting download still tries now and then.
        let stubborn = makeJob()
        stubborn.isOnline = { false }
        stubborn.offlineRetryInterval = .milliseconds(50)
        let marker2 = makeFolder().appendingPathComponent("tried").path
        try await drive(stubborn, script("if [ -e '\(marker2)' ]; then echo '@@F /tmp/ok.mp4'; else touch '\(marker2)'; echo 'ERROR: something odd' >&2; exit 1; fi"))
        expectEqual(stubborn.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
    }

    await suite("DownloadJob: a download that goes silent is restarted") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("tried").path
        let job = makeJob(folder: folder)
        job.stallLimit = .milliseconds(200)
        job.retryDelays = [.milliseconds(10)]
        try await drive(job, script("if [ -e '\(marker)' ]; then echo '@@F /tmp/ok.mp4'; else touch '\(marker)'; echo '\(progressLine("/tmp/ok.mp4"))'; exec sleep 30; fi"))
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
        expect(job.log.contains { $0.contains("no progress") }, "the restart is in the log")

        // aria2 and ffmpeg print nothing while they work; what they write is the sign of life.
        let part = folder.appendingPathComponent("clip [a].mp4.part").path
        let quiet = makeJob(folder: folder)
        quiet.stallLimit = .milliseconds(300)
        quiet.retryDelays = []
        await quiet.run(starter: script("echo '@@D |clip [a].mp4'; for i in 1 2 3 4 5 6 7 8; do echo data >> '\(part)'; sleep 0.1; done; echo '@@F /tmp/ok.mp4'"))
        expectEqual(quiet.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
        expect(!quiet.log.contains { $0.contains("no progress") }, "silent but writing: left alone")

        // …and when the file stops growing too, it has stalled.
        let dead = makeJob(folder: folder)
        dead.stallLimit = .milliseconds(200)
        dead.retryDelays = []
        await dead.run(starter: script("echo '@@D |clip [b].mp4'; echo data > '\(folder.path)/clip [b].mp4.part'; exec sleep 30"))
        expectEqual(dead.state, .failed("The download stopped making progress."))

        // Still starting up (nothing written yet) isn't a stall, however quiet.
        let starting = makeJob(folder: folder)
        starting.stallLimit = .milliseconds(100)
        await starting.run(starter: script("sleep 0.6; echo '@@F /tmp/ok.mp4'"))
        expectEqual(starting.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))
    }

    await suite("DownloadJob: after the Mac wakes, a running download starts again") {
        let marker = makeFolder().appendingPathComponent("tried").path
        let starter = script("if [ -e '\(marker)' ]; then echo '@@F /tmp/ok.mp4'; else touch '\(marker)'; echo '\(progressLine("/tmp/ok.mp4"))'; exec sleep 30; fi")
        let job = makeJob()
        job.retryDelays = []   // it isn't a failure: no retry is used
        let run = Task { @MainActor in await job.run(starter: starter) }
        try await waitUntil { if case .downloading(.some) = job.state { true } else { false } }
        job.restartAfterWake()
        await run.value
        expectEqual(job.state, .queued)
        expect(job.isReadyToRun, "ready at once")
        expectEqual(job.automaticRetry, nil)
        try await drive(job, starter)
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/ok.mp4")))

        let idle = makeJob()
        idle.restartAfterWake()   // nothing running: nothing happens
        expectEqual(idle.state, .queued)
    }

    await suite("DownloadJob: a missing folder or a full disk pauses the download, with the reason") {
        let tools = DownloadTools(ytDlp: sh, ffmpeg: ffmpeg)
        let unplugged = makeJob(folder: URL(fileURLWithPath: "/dev/null/Videos"))
        await unplugged.run(starter: script("echo '@@F /tmp/ok.mp4'"))
        expectEqual(unplugged.state, .paused)
        expectEqual(DownloadFormatting.status(of: unplugged), "Paused · the download folder isn't available")
        // The reason survives a relaunch.
        let restored = DownloadJob(restoring: try JSONDecoder().decode(PendingDownload.self, from: JSONEncoder().encode(unplugged.pendingSnapshot)), tools: tools)
        expectEqual(DownloadFormatting.status(of: restored), "Paused · the download folder isn't available")
        unplugged.resume()
        expectEqual(unplugged.state, .queued)
        expectEqual(unplugged.pauseReason, nil)

        let full = makeJob()
        full.minimumFreeBytes = .max
        await full.run(starter: script("echo '@@F /tmp/ok.mp4'"))
        expectEqual(full.state, .paused)
        expectEqual(DownloadFormatting.status(of: full), "Paused · not enough disk space")

        // The file turns out bigger than the room left: stopped as soon as its size is known.
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let part = folder.appendingPathComponent("big [x].mp4").path
        let big = makeJob(folder: folder)
        await big.run(starter: script(#"touch '\#(part).part'; echo '@@P {"status": "downloading", "downloaded_bytes": 10, "total_bytes": 9000000000000000000, "filename": "\#(part)"}'; exec sleep 30"#))
        expectEqual(big.state, .paused)
        expectEqual(big.pauseReason, .diskFull)
        expect(FileManager.default.fileExists(atPath: part + ".part"), "what it has is kept for resuming")
        expect(big.log.contains { $0.contains("not enough disk space") }, "and the log says why")

        // The disk filled up anyway (yt-dlp's own error).
        let filled = makeJob()
        filled.retryDelays = [.milliseconds(10)]
        await filled.run(starter: script("echo 'ERROR: unable to write data: [Errno 28] No space left on device' >&2; exit 1"))
        expectEqual(filled.state, .paused)
        expectEqual(filled.pauseReason, .diskFull)
    }

    await suite("DownloadJob: a playlist that saved some items is complete; retrying fetches the rest") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(directory: folder)
        var options = DownloadOptions()
        options.downloadPlaylist = true
        let job = makeJob(options)
        job.title = "Mix"
        let seen = Seen()
        await job.run(starter: { _, arguments in
            seen.arguments = arguments
            return try ProcessRunner.start(sh, arguments: ["-c", "echo '@@D 3|a.mp4'; echo '@@F /tmp/a.mp4'; echo 'ERROR: [youtube] b: Private video' >&2; echo '@@D 3|c.mp4'; echo '@@F /tmp/c.mp4'; exit 1"])
        })
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/c.mp4")))
        expectEqual(job.failedItems, 1)
        expectEqual(DownloadFormatting.status(of: job), "2 of 3 saved · MP4")
        let archive = seen.arguments.firstIndex(of: "--download-archive").map { seen.arguments[$0 + 1] }
        expect(archive != nil && seen.arguments.suffix(2).first == "--", "yt-dlp notes what it finished, got \(seen.arguments.suffix(4))")

        library.record(job)
        job.markRecorded()
        expectEqual(library.history.map(\.title), ["Mix", "c", "a"])
        expectEqual(library.history[0].failure, "1 of 3 items couldn't be downloaded.")

        expect(job.canRetry, "the missing item can be retried")
        job.retry()
        expectEqual(job.savedFiles.count, 2)   // what it saved stays
        await job.run(starter: { _, arguments in
            expectEqual(arguments.firstIndex(of: "--download-archive").map { arguments[$0 + 1] }, archive)   // the same notes: only the rest is fetched
            return try ProcessRunner.start(sh, arguments: ["-c", "echo '@@D 3|b.mp4'; echo '@@F /tmp/b.mp4'"])
        })
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/b.mp4")))
        expectEqual(DownloadFormatting.status(of: job), "3 files · MP4")
        expect(!job.canRetry, "nothing left to retry")
        library.record(job)
        expectEqual(library.history.map(\.title), ["b", "Mix", "c", "a"])   // only the new file is added
    }

    await suite("DownloadJob: a failed download is saved and comes back failed, with its log") {
        let job = makeJob()
        await job.run(starter: script("echo 'ERROR: Unsupported URL: https://example.com/v' >&2; exit 1"))
        expectEqual(job.state, .failed("This link isn't supported."))
        let saved = job.pendingSnapshot
        expectEqual(saved?.failure, "This link isn't supported.")
        let data = try JSONEncoder().encode(saved)
        let restored = DownloadJob(restoring: try JSONDecoder().decode(PendingDownload.self, from: data),
                                   tools: DownloadTools(ytDlp: sh, ffmpeg: ffmpeg))
        expectEqual(restored.state, job.state)
        expectEqual(restored.log, job.log)
        expect(restored.canRetry, "and can be retried")
        // A file saved before failures were kept has none of the newer fields: it restores paused.
        var fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        fields["failure"] = nil
        fields["log"] = nil
        let old = try JSONDecoder().decode(PendingDownload.self, from: JSONSerialization.data(withJSONObject: fields))
        expectEqual(DownloadJob(restoring: old, tools: DownloadTools(ytDlp: sh, ffmpeg: ffmpeg)).state, .paused)
    }

    await suite("DownloadFormatting.failure: plain words for common yt-dlp errors") {
        expectEqual(DownloadFormatting.failure("[youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser"),
                    "This site wants you signed in. Choose your browser under Cookies in the download's options, then try again.")
        expectEqual(DownloadFormatting.failure("Unable to download webpage: [Errno 8] nodename nor servname provided, or not known"), "No internet connection.")
        expectEqual(DownloadFormatting.failure("[Errno 28] No space left on device"), "The disk is full.")
        expectEqual(DownloadFormatting.failure("something nobody has seen before"), "something nobody has seen before")
    }

    await suite("OrphanedDownloads: stops only processes whose parent is gone, and waits for them") {
        let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        func alive(_ marker: String) async -> Int {
            ((try? await ProcessRunner.output(of: pgrep, arguments: ["-f", marker])) ?? "").split(separator: "\n").count
        }
        /// Starts a process that outlives its parent (the sh), handling SIGINT as `interrupt` says.
        func orphan(_ marker: String, interrupt: String) async throws {
            _ = try await ProcessRunner.output(of: sh, arguments: ["-c", "/usr/bin/perl -e '$SIG{INT}=q(\(interrupt)); sleep 30' \(marker) >/dev/null 2>&1 &"])
        }

        let marker = "downstream-orphan-\(UUID().uuidString)"
        try await orphan(marker, interrupt: "DEFAULT")
        let child = try ProcessRunner.start(perl, arguments: ["-e", "sleep 30", marker])
        try await Task.sleep(for: .milliseconds(200))
        expectEqual(await alive(marker), 2)
        await OrphanedDownloads.stop(marker: marker)
        expectEqual(await alive(marker), 1)   // gone by the time it returns; our own child is left alone
        child.cancel()

        // One that ignores the polite request is killed.
        let stubborn = "downstream-orphan-\(UUID().uuidString)"
        try await orphan(stubborn, interrupt: "IGNORE")
        try await Task.sleep(for: .milliseconds(200))
        expectEqual(await alive(stubborn), 1)
        await OrphanedDownloads.stop(marker: stubborn, gracePeriod: .milliseconds(300))
        expectEqual(await alive(stubborn), 0)
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

    await suite("PartialFiles: aria2 transfers are cleaned up without reported names") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func touch(_ name: String) { try? Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        // aria2c reports nothing, so the control file and fragments are all there is to go on.
        for name in ["Video [x].mp4", "Video [x].mp4.aria2", "Video [x].mp4.part-Frag1", "Video [x].mp4.f251.webm", "Video [x].nfo"] {
            touch(name)
        }
        // A stale control file from an earlier session must not scope any cleanup.
        let stale = folder.appendingPathComponent("Old [y].mkv.aria2")
        try? Data("x".utf8).write(to: stale)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        touch("Old [y].mkv")

        let removed = PartialFiles.remove(writtenBy: [], in: folder, since: now.addingTimeInterval(-5), keeping: [])
        expect(removed == ["Video [x].mp4", "Video [x].mp4.aria2", "Video [x].mp4.f251.webm", "Video [x].mp4.part-Frag1"], "removed: \(removed)")
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Video [x].nfo").path), "the user's .nfo survives")
        expect(FileManager.default.fileExists(atPath: stale.path), "the stale .aria2 survives")
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Old [y].mkv").path), "the stale target survives")
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

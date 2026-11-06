import Foundation
@testable import DownstreamCore

/// Drives `DownloadJob` with a shell script standing in for yt-dlp, replaying recorded output.
@MainActor
func downloadJobChecks() async {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let context = DownloadContext(url: URL(string: "https://example.com/v")!, outputDirectory: FileManager.default.temporaryDirectory,
                                  ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
    let fixturePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/progress-audio.txt").path

    func script(_ body: String) -> ProcessStarter {
        { _, _ in try ProcessRunner.start(sh, arguments: ["-c", body]) }
    }

    await suite("DownloadJob: replayed audio download completes") {
        let job = DownloadJob(url: context.url, options: DownloadOptions(), title: "Me at the zoo")
        var seen: [DownloadJob.State] = []
        let observer = Task { @MainActor in
            while !Task.isCancelled { if seen.last != job.state { seen.append(job.state) }; await Task.yield() }
        }
        await job.run(context: context, ytDlp: sh, starter: script("cat '\(fixturePath)'"))
        observer.cancel()
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/dl/Me at the zoo.mp3")))
        expectEqual(job.savedFiles.count, 1)
        expect(!job.isActive, "finished jobs aren't active")
        expect(job.log.contains { $0.contains("ExtractAudio") }, "postprocessing lines logged")
        expect(!job.log.contains { $0.hasPrefix("@@P") }, "progress lines not logged")
        expectEqual(DownloadFormatting.status(of: job), "MP3")   // the file doesn't exist here, so no size
    }

    await suite("DownloadJob: yt-dlp error becomes the failure message") {
        let job = DownloadJob(url: context.url, options: DownloadOptions())
        await job.run(context: context, ytDlp: sh, starter: script("echo 'WARNING: meh' >&2; echo 'ERROR: [youtube] abc: Video unavailable' >&2; exit 1"))
        expectEqual(job.state, .failed("[youtube] abc: Video unavailable"))
        expectEqual(DownloadFormatting.status(of: job), "[youtube] abc: Video unavailable")
    }

    await suite("DownloadJob: success without a file is a failure") {
        let job = DownloadJob(url: context.url, options: DownloadOptions())
        await job.run(context: context, ytDlp: sh, starter: script("echo hello"))
        expectEqual(job.state, .failed("yt-dlp finished without saving a file."))
    }

    await suite("DownloadJob: invalid options fail before starting") {
        var options = DownloadOptions()
        options.filenameTemplate = "/etc/x"
        let job = DownloadJob(url: context.url, options: options)
        await job.run(context: context, ytDlp: sh, starter: script("exit 0"))
        if case .failed(let message) = job.state { expect(message.contains("inside the download folder"), message) } else { expect(false, "should fail") }
    }

    await suite("DownloadJob: cancel while downloading") {
        let job = DownloadJob(url: context.url, options: DownloadOptions())
        let progress = #"@@P {"status": "downloading", "downloaded_bytes": 10, "total_bytes": 100, "speed": 5.0, "eta": 18}"#
        let run = Task { @MainActor in await job.run(context: context, ytDlp: sh, starter: script("echo '\(progress)'; exec sleep 30")) }
        for _ in 0..<200 where job.state == .downloading(nil) || job.state == .waiting { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(DownloadFormatting.status(of: job), "10 bytes of 100 bytes · 5 bytes/s · 18 s left")
        job.cancel()
        await run.value
        expectEqual(job.state, .cancelled)
    }

    await suite("DownloadJob: cancel before starting") {
        let job = DownloadJob(url: context.url, options: DownloadOptions())
        job.cancel()
        expectEqual(job.state, .cancelled)
        await job.run(context: context, ytDlp: sh, starter: script("exit 0"))
        expectEqual(job.state, .cancelled)   // a cancelled job never starts
    }

    await suite("DownloadManager: add, totals, remove") {
        let manager = DownloadManager(starter: script("sleep 0.2; echo '@@F /tmp/x.mp4'"))
        let tools = DownloadTools(ytDlp: sh, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = manager.add(url: context.url, options: DownloadOptions(), title: "one", thumbnailURL: nil, outputDirectory: folder, tools: tools)
        let second = manager.add(url: context.url, options: DownloadOptions(), title: "two", thumbnailURL: nil, outputDirectory: folder, tools: tools)
        expectEqual(manager.jobs.map(\.title), ["two", "one"])
        expectEqual(manager.activeCount, 2)
        manager.remove(first)
        expectEqual(manager.jobs.count, 2)   // active jobs can't be removed
        for _ in 0..<300 where manager.activeCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(second.state, .completed(URL(fileURLWithPath: "/tmp/x.mp4")))
        expect(FileManager.default.fileExists(atPath: folder.path), "output folder created")
        manager.removeFinished()
        expectEqual(manager.jobs.count, 0)
    }

    await suite("DownloadFormatting") {
        expectEqual(DownloadFormatting.timeLeft(4.4), "4 s left")
        expectEqual(DownloadFormatting.timeLeft(125), "2 min left")
        expectEqual(DownloadFormatting.timeLeft(3900), "1 hr 5 min left")
        expectEqual(DownloadFormatting.timeLeft(7200), "2 hr left")
        expectEqual(DownloadFormatting.duration(19), "0:19")
        expectEqual(DownloadFormatting.duration(3723), "1:02:03")
        var aria = DownloadOptions()
        aria.aria2Connections = 4
        let job = DownloadJob(url: context.url, options: aria)
        expectEqual(DownloadFormatting.status(of: job), "Waiting")
    }
}

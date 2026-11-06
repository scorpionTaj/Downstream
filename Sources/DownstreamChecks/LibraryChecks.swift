import Foundation
@testable import DownstreamCore

@MainActor
func libraryChecks() async {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let tools = DownloadTools(ytDlp: sh, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))

    func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-library-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func script(_ body: String) -> ProcessStarter {
        { _, _ in try ProcessRunner.start(sh, arguments: ["-c", body]) }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    await suite("JSONFileStore: round trip, missing file, unreadable file kept aside") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JSONFileStore<[String: Int]>(directory: folder, name: "numbers")
        expectEqual(store.load(), nil)
        try store.save(["a": 1])
        expectEqual(store.load(), ["a": 1])
        let text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        expect(text.contains("\"version\" : 1"), "file carries a version: \(text)")

        try Data("not json".utf8).write(to: store.url)
        expectEqual(store.load(), nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        expect(names.contains { $0.hasPrefix("numbers.unreadable-") }, "unreadable file moved aside: \(names)")
        expect(!names.contains("numbers.json"), "original name freed for a fresh file")

        try Data(#"{"version": 99, "value": {"a": 2}}"#.utf8).write(to: store.url)
        expectEqual(store.load(), nil)
        expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("numbers.newer-") },
               "a file from a newer version is kept, not overwritten")
    }

    await suite("Library: history from completed jobs, newest first, persisted") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(directory: folder)
        let context = DownloadContext(url: URL(string: "https://example.com/a")!, outputDirectory: folder, ffmpeg: tools.ffmpeg)
        for name in ["first", "second"] {
            let job = DownloadJob(url: context.url, options: DownloadOptions(), context: context, ytDlp: sh, title: name)
            await job.run(starter: script("echo '@@F /tmp/\(name).mp4'"))
            library.record(job)
        }
        let failed = DownloadJob(url: context.url, options: DownloadOptions(), context: context, ytDlp: sh, title: "bad")
        await failed.run(starter: script("exit 1"))
        library.record(failed)   // ignored: only completed downloads go into history
        expectEqual(library.history.map(\.title), ["second", "first"])
        expectEqual(library.history.first?.file.path, "/tmp/second.mp4")

        let reopened = Library(directory: folder)
        expectEqual(reopened.history, library.history)
        reopened.removeHistory(reopened.history[0])
        expectEqual(Library(directory: folder).history.map(\.title), ["first"])
        reopened.clearHistory()
        expectEqual(Library(directory: folder).history, [])
    }

    await suite("Library: a playlist adds one entry per file") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(directory: folder)
        var options = DownloadOptions()
        options.downloadPlaylist = true
        let context = DownloadContext(url: URL(string: "https://example.com/list")!, outputDirectory: folder, ffmpeg: tools.ffmpeg)
        let job = DownloadJob(url: context.url, options: options, context: context, ytDlp: sh, title: "My list")
        await job.run(starter: script("echo '@@F /tmp/one.mp4'; echo '@@F /tmp/two.mp4'"))
        library.record(job)
        expectEqual(library.history.map(\.title), ["two", "one"])
    }

    await suite("Library: presets") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(directory: folder)
        var audio = DownloadOptions()
        audio.kind = .audio
        audio.audioFormat = .flac
        let preset = library.savePreset(named: "  Lossless audio ", options: audio)
        expectEqual(preset.name, "Lossless audio")
        audio.audioFormat = .opus
        let replaced = library.savePreset(named: "lossless AUDIO", options: audio)
        expectEqual(replaced.id, preset.id)
        expectEqual(library.presets.count, 1)
        expectEqual(Library(directory: folder).presets.first?.options.audioFormat, .opus)
        expectEqual(library.preset(id: preset.id)?.name, "Lossless audio")
        library.deletePreset(preset)
        expectEqual(Library(directory: folder).presets, [])
        expectEqual(library.preset(id: preset.id), nil)
    }

    await suite("Restore: unfinished downloads come back paused and resume") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(directory: folder)
        var saves = 0
        let manager = DownloadManager(maxConcurrent: 1, starter: script("exec sleep 30"))
        manager.onQueueChanged = { saves += 1; library.savePending(manager.pendingDownloads) }
        let part = folder.appendingPathComponent("Clip [r1].mp4").path
        let running = manager.add(url: URL(string: "https://example.com/r1")!, options: DownloadOptions(), title: "running",
                                  thumbnailURL: nil, outputDirectory: folder, tools: tools)
        manager.add(url: URL(string: "https://example.com/r2")!, options: DownloadOptions(), title: "queued",
                    thumbnailURL: nil, outputDirectory: folder, tools: tools)
        expect(saves >= 2, "adding saves the queue")
        try await waitUntil { running.isRunning }
        manager.cancelAll()
        try await waitUntil { manager.runningCount == 0 }
        expectEqual(library.loadPending(), [])   // cancelled downloads aren't restored

        // Simulate a quit with one partly downloaded file.
        FileManager.default.createFile(atPath: part + ".part", contents: Data(count: 40))
        let saved = PendingDownload(url: URL(string: "https://example.com/r1")!, title: "Clip", thumbnailURL: nil,
                                    options: DownloadOptions(), outputDirectory: folder, createdAt: Date(timeIntervalSinceNow: -100),
                                    startedAt: Date(timeIntervalSinceNow: -90), writtenFiles: [part],
                                    lastProgress: .init(downloadedBytes: 40, totalBytes: 100))
        library.savePending([saved])

        let relaunched = DownloadManager(maxConcurrent: 2, starter: script("echo '@@F \(part)'"))
        relaunched.restore(Library(directory: folder).loadPending(), tools: tools)
        let restored = relaunched.jobs[0]
        expectEqual(restored.state, .paused)
        expectEqual(DownloadFormatting.status(of: restored), "Paused · 40 bytes of 100 bytes")
        expectEqual(restored.pendingSnapshot, saved)   // nothing lost in the round trip
        expectEqual(relaunched.runningCount, 0)          // restored downloads wait for the user

        // Cancelling after the relaunch still cleans up the partial file from before it.
        relaunched.cancel(restored)
        expectEqual(restored.state, .cancelled)
        expect(!FileManager.default.fileExists(atPath: part + ".part"), "partial file from the earlier session deleted")

        relaunched.retry(restored)
        try await waitUntil { restored.isFinished }
        expectEqual(restored.state, .completed(URL(fileURLWithPath: part)))
    }

    await suite("DownloadManager: download again from history") {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = DownloadOptions()
        options.kind = .audio
        let entry = HistoryEntry(url: URL(string: "https://example.com/again")!, title: "Again", thumbnailURL: nil,
                                 file: URL(fileURLWithPath: "/tmp/again.mp3"), fileSize: nil, options: options)
        let manager = DownloadManager(starter: script("echo '@@F /tmp/again.mp3'"))
        let job = manager.downloadAgain(entry, outputDirectory: folder, tools: tools)
        expectEqual(job.options, options)
        expectEqual(job.title, "Again")
        try await waitUntil { job.isFinished }
        expectEqual(job.state, .completed(URL(fileURLWithPath: "/tmp/again.mp3")))
    }
}

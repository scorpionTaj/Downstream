import Foundation
@testable import DownstreamCore

/// Fixtures are trimmed real yt-dlp output, read from the source tree.
func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
}

func mediaInfoChecks() async {
    await suite("MediaInfo: single video (real -J output)") {
        let info = try JSONDecoder().decode(MediaInfo.self, from: fixture("video.json"))
        expectEqual(info.id, "jNQXAC9IVRw")
        expectEqual(info.title, "Me at the zoo")
        expectEqual(info.uploader, "jawed")
        expectEqual(info.duration, 19)
        expect(!info.isPlaylist, "a single video isn't a playlist")
        expect(!info.isLive, "not live")
        expectEqual(info.formats.count, 25)
        expect(info.formats.contains { $0.hasVideo && $0.hasAudio }, "has a combined format")
        expect(info.formats.contains { !$0.hasVideo && $0.hasAudio }, "has an audio-only format")
        expect(!info.availableHeights.isEmpty && info.availableHeights == info.availableHeights.sorted(by: >), "heights sorted, highest first: \(info.availableHeights)")
        expectEqual(info.subtitleLanguages, ["de", "en"])
        expect(!info.automaticCaptionLanguages.isEmpty, "has automatic captions")
    }

    await suite("MediaInfo: flat playlist with an unavailable entry") {
        let info = try JSONDecoder().decode(MediaInfo.self, from: fixture("playlist.json"))
        expect(info.isPlaylist, "is a playlist")
        expectEqual(info.entries?.count, 1)   // the null entry is dropped
        expectEqual(info.entries?.first?.id, "jNQXAC9IVRw")
        expectEqual(info.formats, [])
    }

    await suite("MediaInfo: tolerant decoding") {
        let odd = #"{"title": "x", "duration": 12.5, "formats": [{"format_id": "1", "height": 720.0, "vcodec": "avc1", "acodec": "none", "filesize_approx": 1234.0}], "is_live": true}"#
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(odd.utf8))
        expectEqual(info.formats.first?.height, 720)
        expectEqual(info.formats.first?.fileSize, 1234)
        expect(info.formats.first?.hasVideo == true && info.formats.first?.hasAudio == false, "video-only format")
        expect(info.isLive, "is_live is honoured")
        let empty = try JSONDecoder().decode(MediaInfo.self, from: Data("{}".utf8))
        expectEqual(empty.formats, [])
        expect(!empty.isPlaylist, "no entries key, not a playlist")
    }

    await suite("MetadataFetcher error message") {
        expectEqual(MetadataFetcher.errorMessage(from: ["WARNING: x", "ERROR: [generic] 'foo' is not a valid URL", "trailing"]),
                    "[generic] 'foo' is not a valid URL")
        expectEqual(MetadataFetcher.errorMessage(from: ["only line"]), "only line")
    }
}

func argumentBuilderChecks() async {
    let context = DownloadContext(
        url: URL(string: "https://example.com/watch?v=abc")!,
        outputDirectory: URL(fileURLWithPath: "/Users/me/Downloads"),
        ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        aria2c: URL(fileURLWithPath: "/opt/homebrew/bin/aria2c"))

    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    await suite("ArgumentBuilder: URL validation") {
        expectEqual(ArgumentBuilder.validURL("  https://youtu.be/x \n")?.absoluteString, "https://youtu.be/x")
        expectEqual(ArgumentBuilder.validURL("HTTP://example.com")?.host(), "example.com")
        expectEqual(ArgumentBuilder.validURL("file:///etc/passwd"), nil)
        expectEqual(ArgumentBuilder.validURL("--exec rm"), nil)
        expectEqual(ArgumentBuilder.validURL("https://"), nil)
        expectEqual(ArgumentBuilder.validURL("not a url"), nil)
    }

    await suite("ArgumentBuilder: metadata arguments") {
        let args = ArgumentBuilder.metadataArguments(for: URL(string: "https://example.com/watch?v=a&list=b")!, cookies: nil)
        expect(args.contains("--no-playlist"), "a video URL with a &list= parameter stays one video")
        expect(args.contains("--flat-playlist"), "a pure playlist URL is still flattened")
        expectEqual(Array(args.suffix(2)), ["--", "https://example.com/watch?v=a&list=b"])
    }

    await suite("ArgumentBuilder: default video download") {
        let args = try ArgumentBuilder.downloadArguments(DownloadOptions(), context: context)
        expectEqual(Array(args.prefix(1)), ["--ignore-config"])
        expectEqual(Array(args.suffix(2)), ["--", "https://example.com/watch?v=abc"])
        expectEqual(value(after: "--format", in: args), "bv*+ba/b")
        expectEqual(value(after: "--format-sort", in: args), "ext:mp4:m4a")
        expectEqual(value(after: "--merge-output-format", in: args), "mp4")
        expectEqual(value(after: "--remux-video", in: args), "mp4")
        expectEqual(value(after: "--paths", in: args), "/Users/me/Downloads")
        expectEqual(value(after: "--ffmpeg-location", in: args), "/opt/homebrew/bin/ffmpeg")
        expectEqual(value(after: "--print", in: args), "after_move:@@F %(filepath)s")
        for flag in ["--newline", "--progress", "--embed-metadata", "--embed-thumbnail", "--embed-chapters", "--no-playlist"] {
            expect(args.contains(flag), "default includes \(flag)")
        }
        for flag in ["--extract-audio", "--downloader", "--cookies-from-browser", "--sponsorblock-remove", "--limit-rate", "--write-subs"] {
            expect(!args.contains(flag), "default excludes \(flag)")
        }
    }

    await suite("ArgumentBuilder: video quality and containers") {
        var options = DownloadOptions()
        options.maxHeight = 1080
        expectEqual(value(after: "--format-sort", in: try ArgumentBuilder.downloadArguments(options, context: context)), "res:1080,ext:mp4:m4a")
        options.container = .webm
        let webm = try ArgumentBuilder.downloadArguments(options, context: context)
        expectEqual(value(after: "--format-sort", in: webm), "res:1080,ext:webm:webm")
        expect(!webm.contains("--remux-video"), "no remux into WebM")
        expect(!webm.contains("--embed-thumbnail"), "WebM can't hold a thumbnail")
        options.container = .mkv
        let mkv = try ArgumentBuilder.downloadArguments(options, context: context)
        expectEqual(value(after: "--format-sort", in: mkv), "res:1080")
        expectEqual(value(after: "--remux-video", in: mkv), "mkv")
        options.maxHeight = nil
        expect(!(try ArgumentBuilder.downloadArguments(options, context: context)).contains("--format-sort"), "mkv at best quality needs no sort")
    }

    await suite("ArgumentBuilder: audio") {
        var options = DownloadOptions()
        options.kind = .audio
        options.audioFormat = .opus
        options.audioQuality = 3
        options.subtitles = SubtitleOptions(languages: ["en"])
        let args = try ArgumentBuilder.downloadArguments(options, context: context)
        expectEqual(value(after: "--format", in: args), "ba/b")
        expect(args.contains("--extract-audio"), "extracts audio")
        expectEqual(value(after: "--audio-format", in: args), "opus")
        expectEqual(value(after: "--audio-quality", in: args), "3")
        expect(!args.contains("--write-subs") && !args.contains("--merge-output-format"), "no video-only options for audio")
        options.audioFormat = .wav
        expect(!(try ArgumentBuilder.downloadArguments(options, context: context)).contains("--embed-thumbnail"), "WAV can't hold a thumbnail")
    }

    await suite("ArgumentBuilder: subtitles, SponsorBlock, cookies, aria2, rate, playlist") {
        var options = DownloadOptions()
        options.subtitles = SubtitleOptions(languages: ["en", "de"], includeAutomatic: true, embed: true)
        options.sponsorBlock = SponsorBlockOptions(action: .remove, categories: [.sponsor, .selfpromo, .musicOfftopic])
        options.cookies = .browser(.firefox)
        options.aria2Connections = 8
        options.rateLimitKiB = 500
        options.downloadPlaylist = true
        options.playlistItems = "1:5,8"
        let args = try ArgumentBuilder.downloadArguments(options, context: context)
        expectEqual(value(after: "--sub-langs", in: args), "en,de")
        expect(args.contains("--write-auto-subs") && args.contains("--embed-subs"), "subtitle flags")
        expect(!args.contains("--write-subs"), "embedding doesn't also write subtitle files (it would leave a .vtt behind)")
        expectEqual(value(after: "--sponsorblock-remove", in: args), "sponsor,selfpromo,music_offtopic")
        expectEqual(value(after: "--cookies-from-browser", in: args), "firefox")
        expectEqual(value(after: "--downloader", in: args), "/opt/homebrew/bin/aria2c")
        expect(args.contains("dash,m3u8:native"), "fragments stay on the native downloader")
        expectEqual(value(after: "--downloader-args", in: args), "aria2c:-x 8 -s 8 -k 1M")
        expectEqual(value(after: "--limit-rate", in: args), "500K")
        expect(args.contains("--yes-playlist") && !args.contains("--no-playlist"), "playlist mode")
        expectEqual(value(after: "--playlist-items", in: args), "1:5,8")

        options.sponsorBlock = SponsorBlockOptions(action: .mark, categories: [.intro])
        options.cookies = .file(path: "/tmp/cookies.txt")
        var noAria = context
        noAria.aria2c = nil
        let args2 = try ArgumentBuilder.downloadArguments(options, context: noAria)
        expectEqual(value(after: "--sponsorblock-mark", in: args2), "intro")
        expectEqual(value(after: "--cookies", in: args2), "/tmp/cookies.txt")
        options.subtitles = SubtitleOptions(languages: ["en"], embed: false)
        let sidecar = try ArgumentBuilder.downloadArguments(options, context: context)
        expect(sidecar.contains("--write-subs") && !sidecar.contains("--embed-subs"), "keeping subtitles as files")
        expect(!args2.contains("--downloader"), "aria2 ignored when not installed")
    }

    await suite("ArgumentBuilder: validation") {
        func rejects(_ change: (inout DownloadOptions) -> Void, _ label: String) {
            var options = DownloadOptions()
            change(&options)
            expect((try? ArgumentBuilder.downloadArguments(options, context: context)) == nil, "rejects \(label)")
        }
        rejects({ $0.audioQuality = 11 }, "audio quality 11")
        rejects({ $0.aria2Connections = 0 }, "0 aria2 connections")
        rejects({ $0.rateLimitKiB = 0 }, "zero speed limit")
        rejects({ $0.playlistItems = "1;rm -rf" }, "bad playlist items")
        rejects({ $0.filenameTemplate = "/etc/%(title)s.%(ext)s" }, "absolute template")
        rejects({ $0.filenameTemplate = "../%(title)s.%(ext)s" }, "parent-directory template")
        rejects({ $0.filenameTemplate = "~/x.%(ext)s" }, "home template")
        rejects({ $0.filenameTemplate = "  " }, "blank template")
        rejects({ $0.extraArguments = "--format 'best" }, "unclosed quote")

        var badURL = context
        badURL.url = URL(string: "ftp://example.com/x")!
        expect((try? ArgumentBuilder.downloadArguments(DownloadOptions(), context: badURL)) == nil, "rejects ftp URL")

        var subfolder = DownloadOptions()
        subfolder.filenameTemplate = "%(uploader)s/%(title)s.%(ext)s"
        expect((try? ArgumentBuilder.downloadArguments(subfolder, context: context)) != nil, "allows subfolders")
    }

    await suite("ArgumentBuilder: splitting extra arguments") {
        expectEqual(try ArgumentBuilder.splitArguments(""), [])
        expectEqual(try ArgumentBuilder.splitArguments("  --a  b "), ["--a", "b"])
        expectEqual(try ArgumentBuilder.splitArguments(#"--x "two words" 'single $q' esc\ aped"#), ["--x", "two words", "single $q", "esc aped"])
        expectEqual(try ArgumentBuilder.splitArguments(#"--empty "" end"#), ["--empty", "", "end"])
        expectEqual(try ArgumentBuilder.splitArguments(#""in \"quotes\"""#), [#"in "quotes""#])
        var options = DownloadOptions()
        options.extraArguments = "--concurrent-fragments 4"
        let args = try ArgumentBuilder.downloadArguments(options, context: context)
        expectEqual(Array(args.suffix(4)), ["--concurrent-fragments", "4", "--", "https://example.com/watch?v=abc"])
    }

    await suite("DownloadOptions round-trips through JSON") {
        var options = DownloadOptions()
        options.kind = .audio
        options.cookies = .file(path: "~/c.txt")
        options.sponsorBlock = SponsorBlockOptions(action: .mark, categories: [.hook, .musicOfftopic])
        options.subtitles = SubtitleOptions(languages: ["en.*"])
        let decoded = try JSONDecoder().decode(DownloadOptions.self, from: JSONEncoder().encode(options))
        expectEqual(decoded, options)
    }
}

func progressParserChecks() async {
    await suite("ProgressParser: real audio download output") {
        let lines = String(decoding: try fixture("progress-audio.txt"), as: UTF8.self).split(separator: "\n").map(String.init)
        let events = lines.map(ProgressParser.parse)
        let fractions = events.compactMap { if case .downloading(let p) = $0 { p.fraction } else { nil } }
        expect(fractions.count >= 5, "several progress updates (\(fractions.count))")
        expect(fractions == fractions.sorted(), "progress never goes backwards")
        expect(fractions.allSatisfy { (0...1).contains($0) }, "fractions within 0...1")
        expect(events.contains(.downloadFinished(filename: "/tmp/dl/Me at the zoo.mp4")), "download finished event")
        expect(events.contains(.postprocessing(name: "ExtractAudio")), "audio extraction started")
        expect(events.contains(.postprocessingFinished(name: "MoveFiles")), "files moved")
        expect(events.contains(.finalFile(path: "/tmp/dl/Me at the zoo.mp3")), "final file path")
        expect(!events.contains { if case .log = $0 { true } else { false } }, "every captured line was understood")
        if case .downloading(let first)? = events.first {
            expectEqual(first.downloadedBytes, 1024)
            expectEqual(first.totalBytes, 629172)
            expectEqual(first.speed, nil)
        } else {
            expect(false, "first line should be progress")
        }
    }

    await suite("ProgressParser: fragments, estimates, errors and noise") {
        // Shape of an HLS download line: no total_bytes, an estimate and fragment counters.
        let hls = #"@@P {"status": "downloading", "downloaded_bytes": 500, "total_bytes_estimate": 2000.0, "speed": 1000.5, "eta": 2, "fragment_index": 3, "fragment_count": 12}"#
        if case .downloading(let p) = ProgressParser.parse(hls) {
            expectEqual(p.totalBytes, 2000)
            expectEqual(p.fraction, 0.25)
            expectEqual(p.speed, 1000.5)
            expectEqual(p.eta, 2)
        } else {
            expect(false, "HLS line should parse")
        }
        let fragmentsOnly = #"@@P {"status": "downloading", "downloaded_bytes": 0, "fragment_index": 3, "fragment_count": 12}"#
        if case .downloading(let p) = ProgressParser.parse(fragmentsOnly) { expectEqual(p.fraction, 0.25) } else { expect(false, "fragments only") }
        expectEqual(ProgressParser.parse("ERROR: [youtube] abc: Video unavailable"), .error("[youtube] abc: Video unavailable"))
        expectEqual(ProgressParser.parse("WARNING: something odd"), .warning("something odd"))
        expectEqual(ProgressParser.parse("@@P not json"), .log("@@P not json"))
        expectEqual(ProgressParser.parse("[download] Destination: x"), .log("[download] Destination: x"))
        expectEqual(ProgressParser.parse(.stderr("@@Q {\"status\": \"started\", \"postprocessor\": \"Merger\"}")), .postprocessing(name: "Merger"))
        expectEqual(ProgressParser.describe(postprocessor: "Merger"), "Merging video and audio")
        expectEqual(ProgressParser.describe(postprocessor: "Mystery"), "Processing (Mystery)")
    }
}

func processRunnerChecks() async {
    let sh = URL(fileURLWithPath: "/bin/sh")

    await suite("ProcessRunner: both streams, in order per stream") {
        let running = try ProcessRunner.start(sh, arguments: ["-c", "echo out1; echo err1 >&2; echo out2"])
        var out: [String] = [], err: [String] = []
        for try await line in running.lines {
            switch line {
            case .stdout(let s): out.append(s)
            case .stderr(let s): err.append(s)
            }
        }
        expectEqual(out, ["out1", "out2"])
        expectEqual(err, ["err1"])
    }

    await suite("ProcessRunner: very long lines and a missing final newline") {
        // `yt-dlp -J` prints one line of hundreds of kilobytes; Foundation's async line reader hung on it.
        let output = try await ProcessRunner.output(of: sh, arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo; printf 'x\\r\\nlast'"], timeout: .seconds(10))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        expectEqual(lines.map(\.count), [300000, 1, 4])
    }

    await suite("ProcessRunner: arguments are never shell-interpreted") {
        let output = try await ProcessRunner.output(of: URL(fileURLWithPath: "/bin/echo"), arguments: ["$HOME; echo pwned", "`id`"])
        expectEqual(output, "$HOME; echo pwned `id`")
    }

    await suite("ProcessRunner: failure carries exit code and stderr tail") {
        do {
            _ = try await ProcessRunner.output(of: sh, arguments: ["-c", "echo first >&2; echo 'ERROR: boom' >&2; exit 3"])
            expect(false, "should have thrown")
        } catch let error as ProcessError {
            expectEqual(error, .failed(exitCode: 3, stderrTail: ["first", "ERROR: boom"]))
        }
    }

    await suite("ProcessRunner: cancel stops the process") {
        let marker = "downstream-cancel-check-\(UUID().uuidString)"
        let running = try ProcessRunner.start(sh, arguments: ["-c", "echo started; exec sleep 30 # \(marker)"])
        var result: Error?
        let start = ContinuousClock.now
        do {
            for try await line in running.lines where line == .stdout("started") { running.cancel(gracePeriod: .seconds(1)) }
        } catch { result = error }
        expectEqual(result as? ProcessError, .cancelled)
        expect(ContinuousClock.now - start < .seconds(5), "stopped quickly")
    }

    await suite("ProcessRunner: timeout") {
        do {
            _ = try await ProcessRunner.output(of: sh, arguments: ["-c", "exec sleep 30"], timeout: .milliseconds(300))
            expect(false, "should have timed out")
        } catch let error as ProcessError {
            expectEqual(error, .timedOut)
        }
    }

    await suite("ProcessRunner: cancelAndWait") {
        // Stopping a process makes its stream end with .cancelled (as in the cancel suite above).
        // A well-behaved child: SIGINT alone ends it at once.
        let quick = try ProcessRunner.start(sh, arguments: ["-c", "echo started; exec sleep 30"])
        var start = ContinuousClock.now
        do {
            for try await line in quick.lines where line == .stdout("started") { quick.cancelAndWait(deadline: .seconds(5)) }
        } catch { expectEqual(error as? ProcessError, .cancelled) }
        expect(ContinuousClock.now - start < .seconds(3), "SIGINT alone ends it quickly")

        // One that ignores SIGINT: the SIGTERM escalation inside the wait ends it.
        let stubborn = try ProcessRunner.start(sh, arguments: ["-c", #"trap "" INT; echo started; while true; do sleep 0.1; done"#])
        start = ContinuousClock.now
        do {
            for try await line in stubborn.lines where line == .stdout("started") {
                stubborn.cancelAndWait(gracePeriod: .milliseconds(300), deadline: .seconds(5))
            }
        } catch { expectEqual(error as? ProcessError, .cancelled) }
        let took = ContinuousClock.now - start
        expect(took >= .milliseconds(250), "waited out the grace period")
        expect(took < .seconds(3), "SIGTERM escalation ended it")

        // One that ignores both SIGINT and SIGTERM: the SIGKILL escalation ends it (at twice the grace).
        let immovable = try ProcessRunner.start(sh, arguments: ["-c", #"trap "" INT TERM; echo started; while true; do sleep 0.1; done"#])
        start = ContinuousClock.now
        do {
            for try await line in immovable.lines where line == .stdout("started") {
                immovable.cancelAndWait(gracePeriod: .milliseconds(300), deadline: .seconds(5))
            }
        } catch { expectEqual(error as? ProcessError, .cancelled) }
        let killTook = ContinuousClock.now - start
        expect(killTook >= .milliseconds(550), "SIGTERM came first")
        expect(killTook < .seconds(3), "SIGKILL escalation ended it")

        // A deadline shorter than the SIGKILL stage gives up instead of blocking forever.
        let marker = "downstream-cancelandwait-\(UUID().uuidString)"
        let pattern = "downstream-cancelandwait-[0-9a-f]*"
        let immovable2 = try ProcessRunner.start(sh, arguments: ["-c", #"trap "" INT TERM; echo started; while true; do sleep 0.1; done # \#(marker)"#])
        try await Task.sleep(for: .milliseconds(100))   // let it start running
        start = ContinuousClock.now
        immovable2.cancelAndWait(gracePeriod: .milliseconds(500), deadline: .milliseconds(700))
        expect(ContinuousClock.now - start < .seconds(2), "gave up at the deadline, before the SIGKILL stage")
        let stillRunning = try await ProcessRunner.output(of: sh, arguments: ["-c", "pgrep -f '\(pattern)' || true"])
        expect(stillRunning != "", "the process outlived the short wait")
        _ = try? await ProcessRunner.output(of: sh, arguments: ["-c", "pkill -9 -f '\(pattern)'; true"])
    }

    await suite("ProcessRunner: environment") {
        let env = ProcessRunner.environment(for: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"), base: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        expectEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        expectEqual(env["HOME"], "/Users/x")
        expectEqual(env["PYTHONUNBUFFERED"], "1")
    }
}


func advancedOptionChecks() async {
    await suite("PlaylistSelection.spec") {
        expectEqual(PlaylistSelection.spec(selected: [1, 2, 3, 5, 7, 8, 9], count: 10), "1:3,5,7:9")
        expectEqual(PlaylistSelection.spec(selected: [4], count: 10), "4")
        expectEqual(PlaylistSelection.spec(selected: Set(1...10), count: 10), nil)   // everything: no filter
        expectEqual(PlaylistSelection.spec(selected: [], count: 10), nil)
        expectEqual(PlaylistSelection.spec(selected: [2, 99], count: 3), "2")          // out-of-range items ignored
        var options = DownloadOptions()
        options.downloadPlaylist = true
        options.playlistItems = PlaylistSelection.spec(selected: [1, 2, 4], count: 5)
        let args = try ArgumentBuilder.downloadArguments(options, context: DownloadContext(
            url: URL(string: "https://example.com/list")!, outputDirectory: URL(fileURLWithPath: "/tmp"),
            ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")))
        expect(args.contains("1:2,4"), "spec reaches yt-dlp: \(args)")
    }

    await suite("ArgumentBuilder.problem(with:)") {
        expectEqual(ArgumentBuilder.problem(with: DownloadOptions()), nil)
        var options = DownloadOptions()
        options.extraArguments = "--format 'best"
        expectEqual(ArgumentBuilder.problem(with: options), .unbalancedQuote)
        options.extraArguments = ""
        options.filenameTemplate = "../x.%(ext)s"
        expectEqual(ArgumentBuilder.problem(with: options), .invalidFilenameTemplate("../x.%(ext)s"))
    }
}

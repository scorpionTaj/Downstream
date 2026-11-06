import Foundation
import Synchronization

/// One line a child process wrote, tagged with the stream it came from.
/// yt-dlp writes download progress and `--print` output to stdout, and postprocessor progress, warnings and errors to stderr.
public enum OutputLine: Sendable, Equatable {
    case stdout(String)
    case stderr(String)

    public var text: String {
        switch self {
        case .stdout(let text), .stderr(let text): text
        }
    }
}

public enum ProcessError: Error, Equatable, CustomStringConvertible {
    /// The process exited with a non-zero status. `stderrTail` holds its last stderr lines.
    case failed(exitCode: Int32, stderrTail: [String])
    /// `cancel()` stopped it.
    case cancelled
    /// The process didn't finish before the timeout and was stopped.
    case timedOut

    public var description: String {
        switch self {
        case .failed(let code, let tail): "exited with status \(code)" + (tail.isEmpty ? "" : ": " + tail.joined(separator: "\n"))
        case .cancelled: "cancelled"
        case .timedOut: "timed out"
        }
    }
}

/// A started child process. Iterate `lines` to read its output: the stream ends normally on exit status 0,
/// and throws `ProcessError` otherwise. Abandoning the stream stops the process.
public final class RunningProcess: Sendable {
    public let lines: AsyncThrowingStream<OutputLine, Error>
    fileprivate let state: State

    fileprivate init(lines: AsyncThrowingStream<OutputLine, Error>, state: State) {
        self.lines = lines
        self.state = state
    }

    /// Stops the process: SIGINT first so yt-dlp can tidy up, then SIGTERM after `gracePeriod` if it's still running.
    public func cancel(gracePeriod: Duration = .seconds(5)) {
        state.stop(reason: .cancelled, gracePeriod: gracePeriod)
    }

    fileprivate final class State: Sendable {
        enum StopReason { case cancelled, timedOut }

        private let process: Mutex<Process?>
        private let stopReason = Mutex<StopReason?>(nil)

        init(_ process: Process) { self.process = Mutex(process) }

        var reason: StopReason? { stopReason.withLock { $0 } }

        func stop(reason: StopReason, gracePeriod: Duration) {
            let pid: Int32? = process.withLock { process in
                guard let process, process.isRunning else { return nil }
                stopReason.withLock { if $0 == nil { $0 = reason } }
                process.interrupt()
                return process.processIdentifier
            }
            guard let pid else { return }
            Task.detached { [self] in
                try? await Task.sleep(for: gracePeriod)
                process.withLock { process in
                    if let process, process.isRunning, process.processIdentifier == pid { process.terminate() }
                }
            }
        }

        func exited() { process.withLock { $0 = nil } }
    }
}

/// Runs command-line tools without a shell: arguments are passed as-is, so nothing in a URL or file name is ever interpreted.
public enum ProcessRunner {
    /// The environment child processes get: the app's own, with Homebrew's directories and the tool's own directory on `PATH`
    /// (yt-dlp finds ffmpeg and aria2c there), and Python set to unbuffered UTF-8 output so progress arrives line by line.
    public static func environment(for executable: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let directories = [executable.deletingLastPathComponent().path] + ToolLocator.homebrewDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// Starts `executable` and returns immediately. Read its output through `lines`.
    public static func start(_ executable: URL, arguments: [String], stderrTailSize: Int = 20) throws -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(for: executable)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let state = RunningProcess.State(process)
        let (stream, continuation) = AsyncThrowingStream<OutputLine, Error>.makeStream()

        let exitStatus = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitStatus.continuation.yield(finished.terminationStatus)
            exitStatus.continuation.finish()
        }
        try process.run()

        let tail = Mutex<[String]>([])
        Task.detached {
            async let out: Void = readLines(stdout.fileHandleForReading) { continuation.yield(.stdout($0)) }
            async let err: Void = readLines(stderr.fileHandleForReading) { line in
                continuation.yield(.stderr(line))
                tail.withLock { buffer in
                    buffer.append(line)
                    if buffer.count > stderrTailSize { buffer.removeFirst(buffer.count - stderrTailSize) }
                }
            }
            _ = await (out, err)
            // Both pipes hit end-of-file; the exit status follows.
            var status: Int32 = -1
            for await code in exitStatus.stream { status = code }
            state.exited()

            // A clean exit wins over a stop request that arrived too late to matter:
            // the work finished (e.g. yt-dlp was already saving the file when it was cancelled).
            switch state.reason {
            case _ where status == 0: continuation.finish()
            case .cancelled: continuation.finish(throwing: ProcessError.cancelled)
            case .timedOut: continuation.finish(throwing: ProcessError.timedOut)
            case nil: continuation.finish(throwing: ProcessError.failed(exitCode: status, stderrTail: tail.withLock { $0 }))
            }
        }

        continuation.onTermination = { termination in
            // The reader went away (or the task was cancelled) before the process ended: don't leave it running.
            if case .cancelled = termination { state.stop(reason: .cancelled, gracePeriod: .seconds(5)) }
        }
        return RunningProcess(lines: stream, state: state)
    }

    /// Reads `handle` to end-of-file, calling `emit` for each line (without its `\n` or `\r\n`).
    ///
    /// Blocking reads run on a GCD thread, not the Swift concurrency pool, so several downloads can't starve it.
    /// (Foundation's `FileHandle.bytes.lines` was tried first and hangs on very long lines, such as `yt-dlp -J` output.)
    static func readLines(_ handle: FileHandle, emit: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                func emitLine(_ bytes: Data) {
                    var line = bytes
                    if line.last == UInt8(ascii: "\r") { line.removeLast() }
                    emit(String(decoding: line, as: UTF8.self))
                }
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    var start = buffer.startIndex
                    while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                        emitLine(buffer[start..<newline])
                        start = buffer.index(after: newline)
                    }
                    buffer.removeSubrange(buffer.startIndex..<start)
                }
                if !buffer.isEmpty { emitLine(buffer) }
                done.resume()
            }
        }
    }

    /// Runs a short command to completion and returns its stdout. Stops it with `ProcessError.timedOut` after `timeout`.
    public static func output(of executable: URL, arguments: [String], timeout: Duration = .seconds(30)) async throws -> String {
        let running = try start(executable, arguments: arguments)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            running.state.stop(reason: .timedOut, gracePeriod: .seconds(2))
        }
        defer { watchdog.cancel() }
        var lines: [String] = []
        for try await line in running.lines {
            if case .stdout(let text) = line { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }
}

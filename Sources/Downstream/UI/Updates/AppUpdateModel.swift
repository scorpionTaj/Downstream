import AppKit
import DownstreamCore
import Observation

/// Checks GitHub Releases for a newer Downstream, downloads it with progress, installs it and relaunches.
@MainActor
@Observable
final class AppUpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        /// 0...1, or nil before the size is known.
        case downloading(Double?, received: Int64, total: Int64?)
        case installing
        case readyToRelaunch
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The update sheet is open.
    var isPresented = false

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var availableRelease: AppRelease? {
        switch state {
        case .available(let release): release
        default: lastRelease
        }
    }

    var isUpdateAvailable: Bool {
        switch state {
        case .available, .downloading, .installing, .readyToRelaunch: true
        default: false
        }
    }

    private var lastRelease: AppRelease?

    /// Test builds (their own app ID, see scripts/bundle.sh) can read updates from a local feed:
    ///   open build/Downstream.app --args -DownstreamUpdateFeedURL http://127.0.0.1:8765/latest.json
    /// The feed's app then has to be a test build too. Release builds ignore this.
    private var testFeed: URL? {
        guard Bundle.main.object(forInfoDictionaryKey: "DownstreamReleaseBundleID") != nil else { return nil }
        return UserDefaults.standard.string(forKey: "DownstreamUpdateFeedURL").flatMap(URL.init(string:))
    }
    private var downloadTask: Task<Void, Never>?

    /// Checks once a day in the background, if automatic checks are on. Shows the sheet only when there's an update.
    func checkIfDue() {
        guard AppSettings.checkForAppUpdates else { return }
        if let last = AppSettings.lastAppUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    /// "Check for Updates…": always opens the sheet so the result is visible.
    func checkNow() {
        isPresented = true
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await AppUpdater.latestRelease(feed: testFeed)
            AppSettings.lastAppUpdateCheck = Date()
            lastRelease = release
            if AppUpdater.isUpdate(release, over: currentVersion) {
                state = .available(release)
                isPresented = true
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(String(localized: "Couldn't check for updates: \(error.localizedDescription)")) : .idle
        }
    }

    /// Where Downstream runs from, if it can replace itself there.
    private var installLocation: Result<URL, UpdateError> {
        let app = Bundle.main.bundleURL
        let path = app.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return .failure(.cannotReplace(String(localized: "Move Downstream to your Applications folder first, then update.")))
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            return .failure(.cannotReplace(String(localized: "Downstream can't write to \(app.deletingLastPathComponent().path).")))
        }
        return .success(app)
    }

    func downloadAndInstall() {
        guard let release = availableRelease, downloadTask == nil else { return }
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                let app = try installLocation.get()
                guard let asset = release.diskImage else { throw UpdateError.noDiskImage }
                state = .downloading(0, received: 0, total: asset.size > 0 ? asset.size : nil)
                let dmg = try await ProgressDownloader.download(asset.downloadURL) { [weak self] received, total in
                    // Reports arrive from the network thread and can run out of order, even after the download
                    // has finished: only move forward, and only while still downloading.
                    guard let self, case .downloading(_, let shown, _) = state, received >= shown else { return }
                    let total = total ?? (asset.size > 0 ? asset.size : nil)
                    state = .downloading(total.map { min(1, Double(received) / Double(max($0, 1))) }, received: received, total: total)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? NSNumber)?.int64Value ?? asset.size
                state = .downloading(1, received: size, total: size)
                defer { try? FileManager.default.removeItem(at: dmg) }
                // Fail closed: without a published checksum there's nothing to verify the bytes
                // against, and codesign alone wouldn't notice a swapped DMG on a compromised feed.
                guard let checksum = release.checksum else { throw UpdateError.noChecksum }
                let (data, _) = try await URLSession.shared.data(from: checksum.downloadURL)
                try AppUpdater.verify(dmg, checksumFileContents: String(decoding: data, as: UTF8.self))
                state = .installing
                // Test builds have their own app ID but install the real releases.
                let releaseID = testFeed != nil ? Bundle.main.bundleIdentifier ?? ""
                    : Bundle.main.object(forInfoDictionaryKey: "DownstreamReleaseBundleID") as? String
                    ?? Bundle.main.bundleIdentifier ?? "com.scorpiontaj.downstream"
                try await AppUpdater.install(from: dmg, replacing: app, bundleID: releaseID)
                state = .readyToRelaunch
            } catch is CancellationError {
                state = .available(release)
            } catch let error as UpdateError {
                state = .failed(error.description)
            } catch {
                state = .failed(String(localized: "The update couldn't be downloaded: \(error.localizedDescription)"))
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Opens the new version once this one has quit (unfinished downloads are saved and come back paused).
    func relaunch() {
        // macOS won't quit while a sheet is open (this update window is one), so close it first.
        isPresented = false
        AppDelegate.shared?.relaunch()
    }
}

/// Downloads a file to a temporary location, reporting progress on the main actor.
private final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @MainActor (_ received: Int64, _ total: Int64?) -> Void

    private let progress: Progress
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    private init(progress: @escaping Progress) { self.progress = progress }

    static func download(_ url: URL, progress: @escaping Progress) async throws -> URL {
        let downloader = ProgressDownloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.lock.withLock { downloader.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let progress = progress
        Task { @MainActor in progress(totalBytesWritten, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns, so move it now.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Downstream-update-\(UUID().uuidString).dmg")
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }
}

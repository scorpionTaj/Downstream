import CryptoKit
import Foundation

/// A version like `1.2.0` (a leading `v` is ignored). Missing parts count as 0, so `1.2` == `1.2.0`.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let core = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        // Ignore pre-release or build suffixes ("1.2.0-beta", "1.2.0+5") for ordering.
        let numbers = core.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? core
        let parts = numbers.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A GitHub release, as returned by `GET /repos/{owner}/{repo}/releases/latest`.
public struct AppRelease: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public var name: String
        public var downloadURL: URL
        public var size: Int64

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    /// Release notes (Markdown).
    public var notes: String?
    public var pageURL: URL
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, assets
        case tagName = "tag_name"
        case notes = "body"
        case pageURL = "html_url"
    }

    public var version: AppVersion? { AppVersion(tagName) }
    /// The disk image to install from.
    public var diskImage: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
    /// `<dmg name>.sha256`, published next to the disk image.
    public var checksum: Asset? { diskImage.flatMap { dmg in assets.first { $0.name == dmg.name + ".sha256" } } }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case noDiskImage
    case noChecksum
    case checksumMismatch
    case notAnApp
    case wrongApp(bundleID: String?)
    case badSignature(String)
    case cannotReplace(String)

    public var description: String {
        switch self {
        case .noDiskImage: String(localized: "This release has no disk image to install.")
        case .noChecksum: String(localized: "This release has no checksum to verify the download against. Don't install it.")
        case .checksumMismatch: String(localized: "The download is damaged (its checksum doesn't match). Try again.")
        case .notAnApp: String(localized: "The disk image doesn't contain Downstream.")
        case .wrongApp(let id): String(localized: "The disk image contains a different app (\(id ?? "unknown")).")
        case .badSignature(let detail): String(localized: "The new version's signature isn't valid: \(detail)")
        case .cannotReplace(let detail): String(localized: "Couldn't replace the app: \(detail)")
        }
    }
}

/// Finding, checking and installing new versions of Downstream from GitHub Releases.
public enum AppUpdater {
    public static let repository = "scorpionTaj/Downstream"

    /// The newest published release. Unauthenticated GitHub API calls are limited to 60 an hour, plenty for this.
    /// `feed` replaces the GitHub API URL (test builds only, to try updates against a local server).
    public static func latestRelease(repository: String = repository, feed: URL? = nil,
                                     session: URLSession = .shared) async throws -> AppRelease {
        var request = URLRequest(url: feed ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Downstream", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    /// True when `release` is newer than `current`.
    public static func isUpdate(_ release: AppRelease, over current: String) -> Bool {
        guard let new = release.version, let old = AppVersion(current) else { return false }
        return new > old
    }

    /// Hex SHA-256 of a file.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks `dmg` against the first word of a `shasum -a 256` line.
    public static func verify(_ dmg: URL, checksumFileContents: String) throws {
        let expected = checksumFileContents.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard try sha256(of: dmg) == expected else { throw UpdateError.checksumMismatch }
    }

    /// Mounts `dmg`, checks the app inside is a validly signed copy of `bundleID`, and swaps it in for `installedApp`.
    /// The old version is moved to the Trash rather than deleted, so an install can be undone by hand.
    /// Returns the installed app's location.
    @discardableResult
    public static func install(from dmg: URL, replacing installedApp: URL, bundleID: String,
                               trashOldVersion: Bool = true) async throws -> URL {
        try await withMountedImage(dmg) { mountPoint in
            try await installApp(from: mountPoint, replacing: installedApp, bundleID: bundleID, trashOldVersion: trashOldVersion)
        }
    }

    /// Mounts `dmg` read-only, runs `body`, and always unmounts before returning.
    static func withMountedImage<T>(_ dmg: URL, _ body: (URL) async throws -> T) async throws -> T {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("downstream-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output(of: hdiutil, arguments: ["attach", dmg.path, "-nobrowse", "-readonly",
                                                                    "-mountpoint", mountPoint.path], timeout: .seconds(60))
        let result: Result<T, Error>
        do { result = .success(try await body(mountPoint)) } catch { result = .failure(error) }
        _ = try? await ProcessRunner.output(of: hdiutil, arguments: ["detach", mountPoint.path, "-force"], timeout: .seconds(30))
        try? FileManager.default.removeItem(at: mountPoint)
        return try result.get()
    }

    private static func installApp(from mountPoint: URL, replacing installedApp: URL, bundleID: String,
                                   trashOldVersion: Bool) async throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.notAnApp }
        let newID = Bundle(url: newApp)?.bundleIdentifier
        guard newID == bundleID else { throw UpdateError.wrongApp(bundleID: newID) }
        // Not --strict: that also rejects harmless Finder metadata a disk image can carry; the signature is still checked.
        do {
            _ = try await ProcessRunner.output(of: URL(fileURLWithPath: "/usr/bin/codesign"),
                                               arguments: ["--verify", "--deep", newApp.path], timeout: .seconds(60))
        } catch ProcessError.failed(_, let tail) {
            throw UpdateError.badSignature(tail.last ?? "")
        }

        // Copy next to the installed app first (same volume), then swap, so a failure leaves the old app in place.
        let staging = installedApp.deletingLastPathComponent().appendingPathComponent(".\(installedApp.lastPathComponent).new-\(UUID().uuidString)")
        do {
            _ = try await ProcessRunner.output(of: URL(fileURLWithPath: "/usr/bin/ditto"),
                                               arguments: [newApp.path, staging.path], timeout: .seconds(120))
            var trashed: NSURL?
            if trashOldVersion {
                try FileManager.default.trashItem(at: installedApp, resultingItemURL: &trashed)
            } else {
                try FileManager.default.removeItem(at: installedApp)
            }
            do {
                try FileManager.default.moveItem(at: staging, to: installedApp)
            } catch {
                if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: installedApp) }
                throw error
            }
        } catch let error as UpdateError {
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        return installedApp
    }
}

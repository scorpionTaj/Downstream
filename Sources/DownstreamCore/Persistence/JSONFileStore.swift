import Foundation

/// Reads and writes one Codable value as a JSON file, e.g. `~/Library/Application Support/Downstream/history.json`.
///
/// The file holds `{"version": N, "value": …}` so a later format change can migrate old files.
/// Writes are atomic (a crash mid-write leaves the old file intact). A file that can't be read isn't
/// overwritten: it's moved aside as `<name>.unreadable-<timestamp>.json` so nothing is lost silently.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL
    public let version: Int

    public init(directory: URL, name: String, version: Int = 1) {
        self.url = directory.appendingPathComponent("\(name).json")
        self.version = version
    }

    private struct Envelope: Codable {
        var version: Int
        var value: Value
    }

    /// The stored value, or nil if there's no file yet or it couldn't be read (in which case it was moved aside).
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            guard envelope.version <= version else {
                // Written by a newer Downstream: keep it untouched and start empty rather than lose fields.
                moveAside(reason: "newer")
                return nil
            }
            return envelope.value
        } catch {
            moveAside(reason: "unreadable")
            return nil
        }
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Envelope(version: version, value: value))
        try data.write(to: url, options: .atomic)
    }

    private func moveAside(reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let destination = url.deletingLastPathComponent().appendingPathComponent("\(base).\(reason)-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Dates stay as Foundation's own number (seconds since 2001): it round-trips exactly, unlike ISO 8601,
        // which drops fractions of a second.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

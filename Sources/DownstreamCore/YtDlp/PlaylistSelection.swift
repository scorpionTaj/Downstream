import Foundation

/// Turns the items picked from a playlist into yt-dlp's `--playlist-items` syntax.
public enum PlaylistSelection {
    /// 1-based item numbers → e.g. `1:3,5,7:9`. nil when every item (or none) is selected,
    /// meaning "no filter"; callers shouldn't start a download with nothing selected.
    public static func spec(selected: Set<Int>, count: Int) -> String? {
        let items = selected.filter { (1...max(count, 1)).contains($0) }.sorted()
        guard !items.isEmpty, items.count < count else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for item in items {
            if let last = ranges.last, last.upperBound + 1 == item {
                ranges[ranges.count - 1] = last.lowerBound...item
            } else {
                ranges.append(item...item)
            }
        }
        return ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound):\($0.upperBound)" }
            .joined(separator: ",")
    }
}

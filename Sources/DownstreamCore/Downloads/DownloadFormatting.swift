import Foundation

/// Text for the download rows, kept here so it can be checked.
public enum DownloadFormatting {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// The queue's status parts — "1 downloading", "2 queued", "3 paused", the total speed —
    /// shared by the main window header and the menu bar, which add their own extras and pick
    /// their own empty-state text.
    public static func queueSummary(running: Int, queued: Int, paused: Int, speed: Double) -> [String] {
        var parts: [String] = []
        if running > 0 { parts.append(String(localized: "\(running) downloading")) }
        if queued > 0 { parts.append(String(localized: "\(queued) queued")) }
        if paused > 0 { parts.append(String(localized: "\(paused) paused")) }
        if speed > 0 { parts.append(Self.speed(speed)) }
        return parts
    }

    /// "45 s left", "4 min left", "1 hr 5 min left".
    public static func timeLeft(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return String(localized: "\(total) s left") }
        let minutes = total / 60
        if minutes < 60 { return String(localized: "\(minutes) min left") }
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(minutes / 60) hr left") : String(localized: "\(minutes / 60) hr \(rest) min left")
    }

    /// "12:34" or "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The status line under a download's title.
    @MainActor
    public static func status(of job: DownloadJob) -> String {
        switch job.state {
        case .queued:
            return String(localized: "Queued")
        case .paused:
            guard let progress = job.lastProgress else { return String(localized: "Paused") }
            if let total = progress.totalBytes { return String(localized: "Paused · \(bytes(progress.downloadedBytes)) of \(bytes(total))") }
            return String(localized: "Paused · \(bytes(progress.downloadedBytes))")
        case .downloading(nil):
            return job.options.aria2Connections != nil ? String(localized: "Downloading with aria2…") : String(localized: "Starting…")
        case .downloading(let progress?):
            var parts: [String] = []
            if let total = progress.totalBytes {
                parts.append(String(localized: "\(bytes(progress.downloadedBytes)) of \(bytes(total))"))
            } else {
                parts.append(bytes(progress.downloadedBytes))
            }
            if let speed = progress.speed { parts.append(self.speed(speed)) }
            if let eta = progress.eta { parts.append(timeLeft(eta)) }
            if job.options.downloadPlaylist { parts.insert(String(localized: "Item \(job.savedFiles.count + 1)"), at: 0) }
            return parts.joined(separator: " · ")
        case .processing(let step):
            return step + "…"
        case .completed(let file):
            var parts = [file.pathExtension.uppercased()]
            if let size = job.savedFileSize { parts.append(bytes(size)) }
            if job.savedFiles.count > 1 { parts.insert(String(localized: "\(job.savedFiles.count) files"), at: 0) }
            return parts.joined(separator: " · ")
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }
}

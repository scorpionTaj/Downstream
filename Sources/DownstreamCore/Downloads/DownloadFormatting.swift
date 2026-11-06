import Foundation

/// Text for the download rows, kept here so it can be checked.
public enum DownloadFormatting {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// "45 s left", "4 min left", "1 hr 5 min left".
    public static func timeLeft(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s left" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min left" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) hr left" : "\(minutes / 60) hr \(rest) min left"
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
            return "Queued"
        case .paused:
            guard let progress = job.lastProgress else { return "Paused" }
            if let total = progress.totalBytes { return "Paused · \(bytes(progress.downloadedBytes)) of \(bytes(total))" }
            return "Paused · \(bytes(progress.downloadedBytes))"
        case .downloading(nil):
            return job.options.aria2Connections != nil ? "Downloading with aria2…" : "Starting…"
        case .downloading(let progress?):
            var parts: [String] = []
            if let total = progress.totalBytes {
                parts.append("\(bytes(progress.downloadedBytes)) of \(bytes(total))")
            } else {
                parts.append(bytes(progress.downloadedBytes))
            }
            if let speed = progress.speed { parts.append(self.speed(speed)) }
            if let eta = progress.eta { parts.append(timeLeft(eta)) }
            if job.options.downloadPlaylist { parts.insert("Item \(job.savedFiles.count + 1)", at: 0) }
            return parts.joined(separator: " · ")
        case .processing(let step):
            return step + "…"
        case .completed(let file):
            var parts = [file.pathExtension.uppercased()]
            if let size = job.savedFileSize { parts.append(bytes(size)) }
            if job.savedFiles.count > 1 { parts.insert("\(job.savedFiles.count) files", at: 0) }
            return parts.joined(separator: " · ")
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}

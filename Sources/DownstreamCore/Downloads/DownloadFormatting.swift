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

    /// What to tell the user when yt-dlp fails with `message`: a plain explanation and what to do for the
    /// common cases, yt-dlp's own words otherwise. (Those stay in the download's log either way.)
    public static func failure(_ message: String) -> String {
        let text = message.lowercased()
        func has(_ signs: String...) -> Bool { signs.contains(where: text.contains) }
        if has("nodename nor servname", "failed to resolve", "network is unreachable", "network is down",
               "temporary failure in name resolution") {
            return String(localized: "No internet connection.")
        }
        if has("sign in", "log in", "login required", "--cookies") {
            return String(localized: "This site wants you signed in. Choose your browser under Cookies in the download's options, then try again.")
        }
        if has("http error 429", "too many requests") {
            return String(localized: "The site is refusing requests for now. Try again later.")
        }
        if has("in your country", "geo-restricted", "geo restricted") {
            return String(localized: "This isn't available in your country.")
        }
        if has("video unavailable", "private video", "has been removed") {
            return String(localized: "This video is unavailable or private.")
        }
        if has("no space left") {
            return String(localized: "The disk is full.")
        }
        if has("unsupported url") {
            return String(localized: "This link isn't supported.")
        }
        if has("unable to extract", "nsig extraction failed", "requested format is not available") {
            return String(localized: "yt-dlp couldn't read this site. Update yt-dlp (Downstream › Update yt-dlp Now), then try again.")
        }
        return message
    }

    /// The status line under a download's title.
    @MainActor
    public static func status(of job: DownloadJob) -> String {
        switch job.state {
        case .queued:
            if job.waitingForNetwork { return String(localized: "Waiting for the network…") }
            if let retry = job.automaticRetry { return String(localized: "Trying again (\(retry) of \(job.retryDelays.count))…") }
            return String(localized: "Queued")
        case .paused:
            switch job.pauseReason {
            case .folderUnavailable: return String(localized: "Paused · the download folder isn't available")
            case .diskFull: return String(localized: "Paused · not enough disk space")
            case nil: break
            }
            guard let progress = job.lastProgress else { return String(localized: "Paused") }
            if let total = progress.totalBytes { return String(localized: "Paused · \(bytes(progress.downloadedBytes)) of \(bytes(total))") }
            return String(localized: "Paused · \(bytes(progress.downloadedBytes))")
        case .downloading(nil):
            if let retry = job.automaticRetry {
                return String(localized: "Trying again (\(retry) of \(job.retryDelays.count))…")
            }
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
            if job.failedItems > 0 {
                let total = job.playlistTotal ?? job.savedFiles.count + job.failedItems
                parts.insert(String(localized: "\(job.savedFiles.count) of \(total) saved"), at: 0)
            } else if job.savedFiles.count > 1 {
                parts.insert(String(localized: "\(job.savedFiles.count) files"), at: 0)
            }
            switch job.subtitleStatus {
            case .missing: parts.append(String(localized: "Subtitles unavailable"))
            case .retrying: parts.append(String(localized: "Getting subtitles…"))
            case .separate: parts.append(String(localized: "Subtitles in a separate file"))
            case nil: break
            }
            return parts.joined(separator: " · ")
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }
}

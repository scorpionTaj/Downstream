import AppKit
import DownstreamCore
import SwiftUI

/// SponsorBlock, cookies, aria2, speed limit, file names and extra arguments.
/// Used for one download in the Add Download sheet and for the defaults in Settings.
struct AdvancedOptionsView: View {
    @Binding var options: DownloadOptions
    /// aria2c was found. Without it the aria2 option is shown but can't be turned on.
    let aria2Available: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            sponsorBlock
            Divider().gridCellUnsizedAxes(.horizontal)
            cookies
            Divider().gridCellUnsizedAxes(.horizontal)
            speed
            Divider().gridCellUnsizedAxes(.horizontal)
            fileNames
            if let problem = ArgumentBuilder.problem(with: options) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label(problem.description, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: SponsorBlock

    private enum SponsorBlockMode: Hashable { case off, remove, mark }

    private var sponsorBlockMode: Binding<SponsorBlockMode> {
        Binding {
            switch options.sponsorBlock?.action {
            case nil: .off
            case .remove: .remove
            case .mark: .mark
            }
        } set: { mode in
            switch mode {
            case .off: options.sponsorBlock = nil
            case .remove, .mark:
                let action: SponsorBlockOptions.Action = mode == .remove ? .remove : .mark
                options.sponsorBlock = SponsorBlockOptions(action: action, categories: options.sponsorBlock?.categories ?? [.sponsor])
            }
        }
    }

    private func category(_ category: SponsorBlockOptions.Category) -> Binding<Bool> {
        Binding {
            options.sponsorBlock?.categories.contains(category) ?? false
        } set: { on in
            guard var sponsorBlock = options.sponsorBlock else { return }
            sponsorBlock.categories.removeAll { $0 == category }
            if on { sponsorBlock.categories.append(category) }
            // Keep yt-dlp's argument in a stable order.
            sponsorBlock.categories.sort { Self.categoryOrder($0) < Self.categoryOrder($1) }
            options.sponsorBlock = sponsorBlock
        }
    }

    private static func categoryOrder(_ category: SponsorBlockOptions.Category) -> Int {
        SponsorBlockOptions.Category.allCases.firstIndex(of: category) ?? 0
    }

    private static func name(_ category: SponsorBlockOptions.Category) -> String {
        switch category {
        case .sponsor: "Sponsors"
        case .intro: "Intros"
        case .outro: "Endcards"
        case .selfpromo: "Self-promotion"
        case .preview: "Previews and recaps"
        case .filler: "Filler"
        case .interaction: "Subscribe reminders"
        case .musicOfftopic: "Non-music in music videos"
        case .hook: "Hooks"
        }
    }

    @ViewBuilder
    private var sponsorBlock: some View {
        GridRow {
            Text("SponsorBlock").gridColumnAlignment(.trailing)
            Picker("SponsorBlock", selection: sponsorBlockMode) {
                Text("Off").tag(SponsorBlockMode.off)
                Text("Cut out segments").tag(SponsorBlockMode.remove)
                Text("Mark as chapters").tag(SponsorBlockMode.mark)
            }
            .labelsHidden()
            .fixedSize()
        }
        if options.sponsorBlock != nil {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 6) {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 4) {
                        ForEach(SponsorBlockOptions.Category.allCases, id: \.self) { item in
                            Toggle(Self.name(item), isOn: category(item))
                        }
                    }
                    Text("Uses segments submitted by SponsorBlock's community. YouTube only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Cookies

    private enum CookieChoice: Hashable {
        case none
        case browser(CookieSource.Browser)
        case file
    }

    private var cookieChoice: Binding<CookieChoice> {
        Binding {
            switch options.cookies {
            case nil: .none
            case .browser(let browser): .browser(browser)
            case .file: .file
            }
        } set: { choice in
            switch choice {
            case .none: options.cookies = nil
            case .browser(let browser): options.cookies = .browser(browser)
            case .file:
                if case .file = options.cookies { return }
                if let path = Self.chooseCookieFile() { options.cookies = .file(path: path) }
            }
        }
    }

    private static func browserName(_ browser: CookieSource.Browser) -> String {
        switch browser {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        case .brave: "Brave"
        case .edge: "Edge"
        case .chromium: "Chromium"
        case .opera: "Opera"
        case .vivaldi: "Vivaldi"
        }
    }

    @ViewBuilder
    private var cookies: some View {
        GridRow {
            Text("Cookies")
            Picker("Cookies", selection: cookieChoice) {
                Text("Don't use cookies").tag(CookieChoice.none)
                Divider()
                ForEach(CookieSource.Browser.allCases, id: \.self) { browser in
                    Text("From \(Self.browserName(browser))").tag(CookieChoice.browser(browser))
                }
                Divider()
                Text("From a cookies.txt file…").tag(CookieChoice.file)
            }
            .labelsHidden()
            .fixedSize()
        }
        if let note = cookieNote {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cookieNote: String? {
        switch options.cookies {
        case nil:
            "Cookies let yt-dlp download what your browser can see while you're signed in, such as age-restricted or members-only videos."
        case .browser(.safari):
            "Reading Safari's cookies needs Full Disk Access for Downstream: System Settings › Privacy & Security › Full Disk Access."
        case .browser:
            "Your browser may ask for permission the first time."
        case .file(let path):
            (path as NSString).abbreviatingWithTildeInPath
        }
    }

    private static func chooseCookieFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a cookies.txt file in Netscape format"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: Speed

    @ViewBuilder
    private var speed: some View {
        GridRow {
            Text("aria2")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("Download with aria2", isOn: Binding(
                        get: { options.aria2Connections != nil },
                        set: { options.aria2Connections = $0 ? 8 : nil }))
                    .disabled(!aria2Available && options.aria2Connections == nil)
                    if let connections = options.aria2Connections {
                        Stepper("\(connections) connections", value: Binding(
                            get: { connections }, set: { options.aria2Connections = min(16, max(1, $0)) }), in: 1...16)
                            .fixedSize()
                    }
                }
                Text(aria2Available
                     ? "Faster on some sites. The progress bar can't show a percentage while aria2 is downloading."
                     : "Install aria2 with Homebrew to use this: brew install aria2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        GridRow {
            Text("Speed limit")
            HStack {
                Toggle("Limit to", isOn: Binding(
                    get: { options.rateLimitKiB != nil },
                    set: { options.rateLimitKiB = $0 ? 2048 : nil }))
                if options.rateLimitKiB != nil {
                    TextField("KB/s", value: Binding(
                        get: { options.rateLimitKiB ?? 2048 },
                        set: { options.rateLimitKiB = max(1, $0) }), format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                    Text("KB/s")
                }
            }
        }
    }

    // MARK: File names and extra arguments

    @ViewBuilder
    private var fileNames: some View {
        GridRow {
            Text("File name")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Template", text: $options.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button("Reset") { options.filenameTemplate = DownloadOptions().filenameTemplate }
                        .disabled(options.filenameTemplate == DownloadOptions().filenameTemplate)
                }
                Toggle("Use only plain ASCII characters, no spaces", isOn: $options.restrictFilenames)
                Text("yt-dlp output template, e.g. %(uploader)s/%(title)s.%(ext)s puts each channel in its own folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        GridRow {
            Text("Extra arguments")
            VStack(alignment: .leading, spacing: 4) {
                TextField("--concurrent-fragments 4", text: $options.extraArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Text("Passed to yt-dlp as-is, after Downstream's own. They're never run through a shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

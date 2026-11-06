import AppKit
import DownstreamCore
import SwiftUI

/// Settings: General, Downloads, Advanced and About, in the sunset style.
struct SettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape.fill") }
            DownloadSettings()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver.fill") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle.fill") }
        }
        .frame(width: 660, height: 600)
        .onAppear { settings.reload() }
    }
}

/// A grouped-form section whose header is a colored icon tile and a title.
private struct TileSection<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        } header: {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, fill: AnyShapeStyle(color.gradient), size: 22)
                Text(title).font(.headline).foregroundStyle(.primary)
            }
            .padding(.bottom, 2)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            TileSection(title: "Look and language", symbol: "paintpalette.fill", color: Theme.pink) {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("Match the system").tag(AppSettings.Appearance.system)
                    Text("Light").tag(AppSettings.Appearance.light)
                    Text("Dark").tag(AppSettings.Appearance.dark)
                }
                Picker("Language", selection: $settings.language) {
                    Text("Match the system").tag(AppSettings.Language.system)
                    Text(verbatim: "English").tag(AppSettings.Language.en)
                    Text(verbatim: "Français").tag(AppSettings.Language.fr)
                    Text(verbatim: "العربية").tag(AppSettings.Language.ar)
                }
                if settings.language != settings.runningLanguage {
                    LabeledContent {
                        Button("Relaunch now") { AppDelegate.shared?.relaunch() }
                            .buttonStyle(SunsetButtonStyle())
                    } label: {
                        Text("Downstream switches language after a relaunch.").foregroundStyle(.secondary)
                    }
                }
            }

            TileSection(title: "Quitting and the menu bar", symbol: "menubar.rectangle", color: Theme.orange) {
                Picker("When you quit (⌘Q)", selection: $settings.quitBehavior) {
                    Text("Ask every time").tag(AppSettings.QuitBehavior.ask)
                    Text("Keep running in the menu bar").tag(AppSettings.QuitBehavior.keepRunning)
                    Text("Quit").tag(AppSettings.QuitBehavior.quit)
                }
                Toggle("Show Downstream in the menu bar", isOn: $settings.showInMenuBar)
                Toggle(isOn: $settings.hideDockIcon) {
                    Text("Hide the Dock icon")
                    Text("Downstream then lives in the menu bar only. Open the window from there.")
                }
                .disabled(!settings.showInMenuBar)
            }

            TileSection(title: "Notifications", symbol: "bell.badge.fill", color: Theme.purple) {
                Toggle("Notify when a download finishes while Downstream is in the background", isOn: $settings.notificationsEnabled)
            }

            TileSection(title: "Help", symbol: "questionmark.circle.fill", color: Theme.green) {
                LabeledContent("New to Downstream?") {
                    Button("Show the welcome guide") { AppDelegate.shared?.showWelcome() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Downloads

private struct DownloadSettings: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        @Bindable var settings = settings
        Form {
            TileSection(title: "Where and how many", symbol: "folder.fill", color: Theme.orange) {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text(settings.downloadFolder.abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.downloadFolder.path)
                        Button("Change…") { chooseFolder() }
                    }
                }
                Stepper(value: $settings.maxConcurrent, in: 1...10) {
                    LabeledContent("Downloads at the same time", value: "\(settings.maxConcurrent)")
                }
            }

            TileSection(title: "New downloads start as", symbol: "slider.horizontal.3", color: Theme.pink) {
                Picker("Type", selection: $settings.defaultOptions.kind) {
                    Text("Video").tag(DownloadOptions.Kind.video)
                    Text("Audio only").tag(DownloadOptions.Kind.audio)
                }
                .pickerStyle(.segmented)
                if settings.defaultOptions.kind == .video {
                    Picker("Quality", selection: $settings.defaultOptions.maxHeight) {
                        Text("Best available").tag(Int?.none)
                        ForEach(AddDownloadModel.standardHeights, id: \.self) { Text(verbatim: "\($0)p").tag(Int?.some($0)) }
                    }
                    Picker("Format", selection: $settings.defaultOptions.container) {
                        ForEach(DownloadOptions.VideoContainer.allCases, id: \.self) { Text(verbatim: $0.rawValue.uppercased()).tag($0) }
                    }
                } else {
                    Picker("Format", selection: $settings.defaultOptions.audioFormat) {
                        ForEach(DownloadOptions.AudioFormat.allCases, id: \.self) { Text(verbatim: $0.rawValue.uppercased()).tag($0) }
                    }
                }
                Toggle("Embed the thumbnail", isOn: $settings.defaultOptions.embedThumbnail)
                Toggle("Embed metadata (title, artist, date…)", isOn: $settings.defaultOptions.embedMetadata)
                Toggle("Embed chapters", isOn: $settings.defaultOptions.embedChapters)
                Text("Presets in the Add Download window can override these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TileSection(title: "SponsorBlock, cookies, speed and file names", symbol: "sparkles", color: Theme.purple) {
                AdvancedOptionsView(options: $settings.defaultOptions, aria2Available: tools.downloadTools?.aria2c != nil)
                    .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.downloadFolder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(ToolSetupModel.self) private var tools
    @Environment(AppUpdateModel.self) private var updates

    var body: some View {
        @Bindable var settings = settings
        Form {
            TileSection(title: "Tools", symbol: "hammer.fill", color: Theme.orange) {
                ForEach(Tool.allCases) { tool in
                    let found = tools.report?[tool]?.isFound == true
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(found ? Theme.green : (tool.isRequired ? Theme.red : .secondary))
                            Text(verbatim: tool.displayName).fontWeight(.semibold)
                            Text(status(of: tool)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        HStack {
                            TextField("Custom path (optional)", text: path(for: tool))
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                            Button("Choose…") { choosePath(for: tool) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                LabeledContent {
                    Button("Check again") { Task { await tools.refresh() } }
                        .disabled(tools.isChecking)
                } label: {
                    Text("Downstream looks in the custom path first, then in Homebrew's folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TileSection(title: "yt-dlp updates", symbol: "arrow.triangle.2.circlepath", color: Theme.pink) {
                Toggle("Update yt-dlp automatically once a week", isOn: $settings.autoUpdateYtDlp)
                LabeledContent {
                    HStack {
                        if tools.isUpdating { ProgressView().controlSize(.small) }
                        Button("Update now") { if let brew = tools.report?.brewURL { tools.updateYtDlp(brew: brew) } }
                            .disabled(tools.isUpdating || tools.report?.brewURL == nil)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sites change often; a newer yt-dlp usually fixes failing downloads.")
                        if let result = tools.updateResult {
                            Text(result).font(.caption).foregroundStyle(.secondary)
                        } else if let last = AppSettings.lastYtDlpUpdate {
                            Text("Last updated \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if tools.report?.brewURL == nil {
                    Text("Homebrew wasn't found. If you installed yt-dlp another way, update it the same way (for example yt-dlp -U).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TileSection(title: "Downstream updates", symbol: "sparkles", color: Theme.purple) {
                Toggle("Check for new versions of Downstream every day", isOn: $settings.checkForAppUpdates)
                LabeledContent("Downstream \(updates.currentVersion)") {
                    Button("Check now") { updates.checkNow() }
                }
            }

            TileSection(title: "Your data", symbol: "externaldrive.fill", color: Theme.indigo) {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppSettings.dataDirectory) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History, presets and unfinished downloads")
                        Text(AppSettings.dataDirectory.abbreviatedPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func status(of tool: Tool) -> String {
        guard let status = tools.report?[tool] else { return String(localized: "Checking…") }
        guard let url = status.url else { return tool.isRequired ? String(localized: "Not found") : String(localized: "Not found (optional)") }
        return String(localized: "\(status.version ?? String(localized: "Unknown version")) at \(url.path)")
    }

    private func path(for tool: Tool) -> Binding<String> {
        Binding(get: { settings.toolPaths[tool] ?? "" }, set: { settings.toolPaths[tool] = $0 })
    }

    private func choosePath(for tool: Tool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = String(localized: "Choose the \(tool.displayName) program")
        if panel.runModal() == .OK, let url = panel.url {
            settings.toolPaths[tool] = url.path
            Task { await tools.refresh() }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(AppUpdateModel.self) private var updates

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: Theme.pink.opacity(0.35), radius: 12, y: 6)
                        .accessibilityHidden(true)
                    Text(verbatim: "Downstream").font(.largeTitle.weight(.bold))
                    Text("Version \(updates.currentVersion)").foregroundStyle(.secondary)
                    Text("Download video and audio from YouTube and the other sites yt-dlp supports, right on your Mac.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                HStack(spacing: 10) {
                    Button("Check for Updates…") { updates.checkNow() }
                        .buttonStyle(SunsetButtonStyle())
                    Link(destination: AppDelegate.links.repository) { Text(verbatim: "GitHub") }
                        .buttonStyle(SunsetButtonStyle(prominent: false))
                    Link(destination: AppDelegate.links.issues) { Text("Report a Problem…") }
                        .buttonStyle(SunsetButtonStyle(prominent: false))
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        IconTile(symbol: "list.bullet.rectangle.fill", size: 22)
                        Text("What's new").font(.headline)
                    }
                    ChangelogView(limit: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(accent: Theme.pink)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Made with").font(.headline)
                    Text("yt-dlp, ffmpeg, aria2 and SponsorBlock do the heavy lifting. Downstream is free and open source under the MIT license, and contains no code from Parabolic or Macabolic, which inspired it.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Download only content you own or have permission to download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(24)
        }
        .background(Theme.backdrop)
    }
}

/// Releases from the bundled CHANGELOG.md, newest first.
struct ChangelogView: View {
    /// Show at most this many releases; nil for all.
    let limit: Int?
    /// Show only this version, e.g. for "What's New".
    var only: String? = nil

    var body: some View {
        let releases = Self.changelog.releases.filter { only == nil || $0.version == only }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(releases.prefix(limit ?? releases.count))) { release in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: release.version)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.sunset)
                        if let date = release.date {
                            Text(verbatim: date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(release.sections.enumerated()), id: \.offset) { _, section in
                        Text(verbatim: section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(section.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(Theme.pink).frame(width: 5, height: 5)
                                Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if releases.isEmpty {
                Text("No changelog in this build.").foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    static let changelog: Changelog = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Changelog(markdown: "") }
        return Changelog(markdown: text)
    }()
}

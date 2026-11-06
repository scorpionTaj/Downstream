import AppKit
import DownstreamCore
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            DownloadDefaultsSettings()
                .tabItem { Label("Download defaults", systemImage: "slider.horizontal.3") }
            ToolsSettings()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 620)
        .onAppear { settings.reload() }
    }
}

private struct GeneralSettings: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            LabeledContent("Save downloads to") {
                HStack {
                    Text(settings.downloadFolder.abbreviatedPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.downloadFolder.path)
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.directoryURL = settings.downloadFolder
                        panel.prompt = "Choose"
                        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url }
                    }
                }
            }
            Stepper(value: $settings.maxConcurrent, in: 1...10) {
                LabeledContent("Downloads at the same time", value: "\(settings.maxConcurrent)")
            }
            Toggle("Notify when a download finishes while Downstream is in the background", isOn: $settings.notificationsEnabled)
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

private struct DownloadDefaultsSettings: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New downloads start from these unless you choose a preset.")
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Type").gridColumnAlignment(.trailing)
                        Picker("Type", selection: $settings.defaultOptions.kind) {
                            Text("Video").tag(DownloadOptions.Kind.video)
                            Text("Audio only").tag(DownloadOptions.Kind.audio)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if settings.defaultOptions.kind == .video {
                        GridRow {
                            Text("Quality")
                            Picker("Quality", selection: $settings.defaultOptions.maxHeight) {
                                Text("Best available").tag(Int?.none)
                                ForEach(AddDownloadModel.standardHeights, id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        GridRow {
                            Text("Format")
                            Picker("Format", selection: $settings.defaultOptions.container) {
                                ForEach(DownloadOptions.VideoContainer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    } else {
                        GridRow {
                            Text("Format")
                            Picker("Format", selection: $settings.defaultOptions.audioFormat) {
                                ForEach(DownloadOptions.AudioFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    GridRow {
                        Text("Embed")
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Thumbnail", isOn: $settings.defaultOptions.embedThumbnail)
                            Toggle("Metadata (title, artist, date…)", isOn: $settings.defaultOptions.embedMetadata)
                            Toggle("Chapters", isOn: $settings.defaultOptions.embedChapters)
                        }
                    }
                }
                Divider()
                AdvancedOptionsView(options: $settings.defaultOptions, aria2Available: tools.downloadTools?.aria2c != nil)
            }
            .padding(20)
        }
        .frame(height: 520)
    }
}

private struct ToolsSettings: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(Tool.allCases) { tool in
                    GridRow {
                        Text(tool.displayName).gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status(of: tool))
                                .foregroundStyle(tools.report?[tool]?.isFound == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                            HStack {
                                TextField("Custom path (optional)", text: path(for: tool))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospaced())
                                Button("Choose…") { choosePath(for: tool) }
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Downstream looks in the custom path first, then in Homebrew's folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check again") { Task { await tools.refresh() } }
                    .disabled(tools.isChecking)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Update yt-dlp").font(.headline)
                Text("Sites change often, and a newer yt-dlp is usually the fix when downloads start failing.")
                    .foregroundStyle(.secondary)
                if let brew = tools.report?.brewURL {
                    HStack {
                        Button("Update with Homebrew") { tools.updateYtDlp(brew: brew) }
                            .disabled(tools.isUpdating)
                        if tools.isUpdating { ProgressView().controlSize(.small) }
                        if let result = tools.updateResult { Text(result).foregroundStyle(.secondary) }
                    }
                    if !tools.updateOutput.isEmpty {
                        ScrollView {
                            Text(tools.updateOutput.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(height: 110)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    Text("Homebrew wasn't found. If you installed yt-dlp another way, update it the same way (for example yt-dlp -U).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(height: 470, alignment: .top)
    }

    private func status(of tool: Tool) -> String {
        guard let status = tools.report?[tool] else { return "Checking…" }
        guard let url = status.url else { return tool.isRequired ? "Not found" : "Not found (optional)" }
        return "\(status.version ?? "Unknown version") at \(url.path)"
    }

    private func path(for tool: Tool) -> Binding<String> {
        Binding(get: { settings.toolPaths[tool] ?? "" }, set: { settings.toolPaths[tool] = $0 })
    }

    private func choosePath(for tool: Tool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(tool.displayName) program"
        if panel.runModal() == .OK, let url = panel.url {
            settings.toolPaths[tool] = url.path
            Task { await tools.refresh() }
        }
    }
}

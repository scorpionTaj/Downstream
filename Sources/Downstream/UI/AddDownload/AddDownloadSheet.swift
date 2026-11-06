import DownstreamCore
import SwiftUI

struct AddDownloadSheet: View {
    @Environment(AddDownloadModel.self) private var model
    @Environment(DownloadManager.self) private var downloads
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.down", size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add download").font(.title2.weight(.bold))
                    Text("Video or audio from any site yt-dlp supports").font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Link").foregroundStyle(.secondary)
                HStack {
                    TextField("https://www.youtube.com/watch?v=…", text: $model.urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(fetch)
                        .onChange(of: model.urlText) { model.urlTextChanged() }
                    Button("Fetch", action: fetch)
                        .disabled(model.phase == .fetching || model.urlText.isEmpty)
                }
            }

            switch model.phase {
            case .idle:
                Text("Paste a link from YouTube, Vimeo or hundreds of other sites.")
                    .foregroundStyle(.secondary)
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting video info…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .ready(let info):
                MediaPreview(info: info)
                // Choices can outgrow the window (a long playlist, More options), so they scroll.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let entries = info.entries, !entries.isEmpty {
                            PlaylistPicker(entries: entries, selection: $model.selectedItems)
                        }
                        choices
                        DisclosureGroup("More options") {
                            AdvancedOptionsView(options: $model.options, aria2Available: tools.downloadTools?.aria2c != nil)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .frame(maxHeight: 380)
            }

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.folder.abbreviatedPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.folder.path)
                    .accessibilityLabel("Save to \(model.folder.abbreviatedPath)")
                Button("Change…") { model.chooseFolder() }
                    .buttonStyle(.link)
                    .accessibilityLabel("Change download folder")
            }

            HStack {
                if let blocker = model.downloadBlocker, !blocker.isEmpty {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") {
                    if let downloadTools = tools.downloadTools { model.start(in: downloads, tools: downloadTools) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SunsetButtonStyle())
                .opacity(model.downloadBlocker != nil || tools.downloadTools == nil ? 0.5 : 1)
                .disabled(model.downloadBlocker != nil || tools.downloadTools == nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .alert("Save preset", isPresented: $model.isNamingPreset) {
            TextField("Name", text: $model.newPresetName)
            Button("Save") { model.saveNamedPreset() }
                .disabled(model.newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves these choices so you can use them again. A preset with the same name is replaced.")
        }
    }

    private func fetch() {
        if let ytDlp = tools.downloadTools?.ytDlp { model.fetch(ytDlp: ytDlp) }
    }

    @ViewBuilder
    private var choices: some View {
        @Bindable var model = model

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Preset").gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    Picker("Preset", selection: Binding(get: { model.presetID }, set: { model.applyPreset(id: $0) })) {
                        Text("Default settings").tag(UUID?.none)
                        if !model.presets.isEmpty { Divider() }
                        ForEach(model.presets) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.isPresetEdited {
                        Text("Edited").font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    Button("Save as preset…") { model.beginSavingPreset() }
                        .fixedSize()
                    if model.presetID != nil {
                        Button("Delete preset", systemImage: "trash") { model.deleteSelectedPreset() }
                            .labelStyle(.iconOnly)
                            .help("Delete this preset")
                    }
                }
            }
            if model.presetID != nil {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Use this preset for new downloads",
                           isOn: Binding(get: { model.isDefaultPreset }, set: { model.setDefaultPreset($0) }))
                        .fixedSize()
                }
            }
            GridRow {
                Text("Type")
                Picker("Type", selection: $model.kind) {
                    Text("Video").tag(DownloadOptions.Kind.video)
                    Text("Audio only").tag(DownloadOptions.Kind.audio)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if model.kind == .video {
                GridRow {
                    Text("Quality")
                    Picker("Quality", selection: $model.maxHeight) {
                        Text("Best available").tag(Int?.none)
                        ForEach(model.heightChoices, id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Format")
                    Picker("Format", selection: $model.container) {
                        ForEach(DownloadOptions.VideoContainer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if !model.subtitleChoices.isEmpty {
                    GridRow {
                        Text("Subtitles")
                        HStack {
                            Toggle("Embed subtitles", isOn: $model.subtitlesEnabled)
                                .fixedSize()
                            Picker("Language", selection: $model.subtitleLanguage) {
                                ForEach(model.subtitleChoices, id: \.self) { code in
                                    Text(Self.languageName(code) + (model.isAutomatic(code) ? " (automatic)" : "")).tag(code)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            .disabled(!model.subtitlesEnabled)
                        }
                    }
                }
            } else {
                GridRow {
                    Text("Format")
                    Picker("Format", selection: $model.audioFormat) {
                        ForEach(DownloadOptions.AudioFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Embed thumbnail and metadata", isOn: $model.embedThumbnailAndMetadata)
            }
        }
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Thumbnail, title and details of what the link points to.
struct MediaPreview: View {
    let info: MediaInfo

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: info.thumbnail.flatMap(URL.init(string:)), width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? String(localized: "Untitled"))
                    .font(.headline)
                    .lineLimit(2)
                Text(details)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.backdrop, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.pink.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if let uploader = info.uploader { parts.append(uploader) }
        if let entries = info.entries {
            parts.append(String(localized: "Playlist · \(entries.count) videos"))
        } else if info.isLive {
            parts.append(String(localized: "Live"))
        } else if let duration = info.duration {
            parts.append(DownloadFormatting.duration(duration))
        }
        return parts.joined(separator: " · ")
    }
}

/// A 16:9 thumbnail, or a placeholder while it loads or when there's none.
struct Thumbnail: View {
    let url: URL?
    var width: CGFloat = 64

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: width * 0.22))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sunsetDiagonal.opacity(0.75))
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: width > 80 ? 10 : 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

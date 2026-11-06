import AppKit
import DownstreamCore
import SwiftUI

/// The first-launch guide: what Downstream does, how to use it, and the one rule (download only what you may).
struct WelcomeView: View {
    @Environment(MainWindowModel.self) private var window
    @Environment(ToolSetupModel.self) private var tools

    private struct Page {
        let symbol: String
        let color: Color
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        let points: [(symbol: String, text: LocalizedStringKey)]
    }

    private let pages: [Page] = [
        Page(symbol: "arrow.down", color: Theme.pink, title: "Welcome to Downstream",
             text: "Download video and audio from YouTube, Vimeo and over a thousand other sites, right on your Mac.",
             points: [("film.stack", "Video up to 4K, or audio only in MP3, FLAC and more"),
                      ("list.bullet.rectangle", "Playlists, subtitles, thumbnails and chapters"),
                      ("lock.shield", "Free, open source and private: everything runs on your Mac")]),
        Page(symbol: "doc.on.clipboard", color: Theme.orange, title: "Add a download",
             text: "Copy a link in your browser, then come back to Downstream.",
             points: [("plus.circle", "Click Add download (⌘N): the copied link is filled in for you"),
                      ("slider.horizontal.3", "Pick video or audio, quality and format, then Download"),
                      ("bolt", "Or press ⇧⌘V to download the copied link straight away")]),
        Page(symbol: "pause.circle", color: Theme.purple, title: "Stay in control",
             text: "Downloads run in a queue you can manage at any time.",
             points: [("playpause", "Pause, resume, retry or cancel each download"),
                      ("menubar.rectangle", "Watch and control downloads from the menu bar"),
                      ("clock.arrow.circlepath", "History keeps every finished download, ready to get again")]),
        Page(symbol: "gearshape", color: Theme.indigo, title: "Make it yours",
             text: "Settings has everything else.",
             points: [("bookmark", "Save your favorite choices as presets"),
                      ("scissors", "Skip sponsors with SponsorBlock, use your browser's cookies"),
                      ("arrow.triangle.2.circlepath", "Downstream and yt-dlp keep themselves up to date")]),
    ]

    private var isLastPage: Bool { window.welcomePage >= pages.count }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.sunsetDiagonal.opacity(0.9)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                    .accessibilityHidden(true)
            }
            .frame(height: 150)

            Group {
                if isLastPage { finalPage } else { page(pages[window.welcomePage]) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 24)

            HStack {
                HStack(spacing: 7) {
                    ForEach(0...pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == window.welcomePage ? AnyShapeStyle(Theme.sunset) : AnyShapeStyle(.quaternary))
                            .frame(width: index == window.welcomePage ? 22 : 8, height: 8)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Page \(window.welcomePage + 1) of \(pages.count + 1)")
                Spacer()
                if window.welcomePage > 0 {
                    Button("Back") { window.welcomePage -= 1 }
                }
                if isLastPage {
                    Button("Get started") { finish() }
                        .buttonStyle(SunsetButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next") { window.welcomePage += 1 }
                        .buttonStyle(SunsetButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 520)
        .animation(.easeInOut(duration: 0.2), value: window.welcomePage)
    }

    private func page(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: page.symbol, fill: AnyShapeStyle(page.color.gradient), size: 40)
                Text(page.title).font(.title.weight(.bold))
            }
            Text(page.text).font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(page.points.enumerated()), id: \.offset) { _, point in
                    Label { Text(point.text) } icon: {
                        Image(systemName: point.symbol).foregroundStyle(page.color)
                    }
                    .font(.body)
                }
            }
            .padding(.top, 6)
        }
    }

    private var finalPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "checkmark.seal", fill: AnyShapeStyle(Theme.green.gradient), size: 40)
                Text("Before you start").font(.title.weight(.bold))
            }
            Text("Downstream uses yt-dlp and ffmpeg from Homebrew.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Tool.allCases) { tool in
                    let found = tools.report?[tool]?.isFound == true
                    Label {
                        if found || tool.isRequired { Text(verbatim: tool.displayName) } else { Text("\(tool.displayName) (optional)") }
                    } icon: {
                        Image(systemName: found ? "checkmark.circle.fill" : (tool.isRequired ? "xmark.circle.fill" : "minus.circle"))
                            .foregroundStyle(found ? Theme.green : (tool.isRequired ? Theme.red : .secondary))
                    }
                }
            }
            if tools.downloadTools == nil {
                Text("Something's missing: Downstream will show you the command to install it.")
                    .font(.callout)
                    .foregroundStyle(Theme.red)
            }
            Text("Only download content you own or have permission to download, and follow each site's terms.")
                .font(.callout.weight(.medium))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "acceptedNotice")
        window.showWelcome = false
    }
}

/// After an update: the changelog for the version now running.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in Downstream").font(.title2.weight(.bold))
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            }
            ScrollView { ChangelogView(limit: 1, only: version).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Continue") { dismiss() }
                    .buttonStyle(SunsetButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// A version string that can drive `.sheet(item:)`.
struct VersionItem: Identifiable {
    let version: String
    var id: String { version }
}

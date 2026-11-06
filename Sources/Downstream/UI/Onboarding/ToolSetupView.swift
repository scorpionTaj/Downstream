import DownstreamCore
import SwiftUI

/// First-run screen: what's missing and the one command that installs it.
struct ToolSetupView: View {
    @Environment(ToolSetupModel.self) private var tools

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                IconTile(symbol: "wrench.and.screwdriver.fill", size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install the download tools")
                        .font(.title2.weight(.semibold))
                    Text("Downstream uses yt-dlp and ffmpeg from Homebrew to download and convert media.")
                        .foregroundStyle(.secondary)
                }
            }

            if let report = tools.report {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.statuses) { ToolStatusRow(status: $0) }
                }

                if report.brewURL == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("Homebrew isn't installed. Install it first, then run the command below.")
                        Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                    }
                }

                if let command = report.installCommand {
                    InstallCommandBox(command: command)
                }
            } else {
                ProgressView("Checking for tools…")
            }

            Spacer(minLength: 0)

            HStack {
                if tools.didCopyCommand {
                    Label("Copied. Paste it into Terminal.", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy command") { tools.copyInstallCommand() }
                    .disabled(tools.report?.installCommand == nil)
                Button("Check again") { Task { await tools.refresh() } }
                    .keyboardShortcut("r")
                    .buttonStyle(SunsetButtonStyle())
                    .disabled(tools.isChecking)
            }
        }
        .padding(28)
    }
}

private struct ToolStatusRow: View {
    let status: ToolStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
            if let path = status.url?.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let name = status.tool.displayName
        if status.isFound { return "\(name) \(status.version ?? String(localized: "(version unknown)"))" }
        return status.tool.isRequired ? String(localized: "\(name) not found") : String(localized: "\(name) not found (optional, for faster downloads)")
    }

    private var symbol: String {
        if status.isFound { return "checkmark.circle.fill" }
        return status.tool.isRequired ? "xmark.circle.fill" : "minus.circle"
    }

    private var color: Color {
        if status.isFound { return .green }
        return status.tool.isRequired ? .red : .secondary
    }
}

private struct InstallCommandBox: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run this in Terminal:")
                .foregroundStyle(.secondary)
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

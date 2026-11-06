import DownstreamCore
import SwiftUI

/// Checkboxes for the videos of a playlist. `selection` holds 1-based item numbers, as yt-dlp counts them.
struct PlaylistPicker: View {
    let entries: [PlaylistEntry]
    @Binding var selection: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(selection.count) of \(entries.count) videos selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select all") { selection = Set(1...entries.count) }
                    .disabled(selection.count == entries.count)
                Button("Select none") { selection = [] }
                    .disabled(selection.isEmpty)
            }
            List {
                ForEach(Array(entries.enumerated()), id: \.offset) { offset, entry in
                    let number = offset + 1
                    Toggle(isOn: Binding(
                        get: { selection.contains(number) },
                        set: { on in if on { selection.insert(number) } else { selection.remove(number) } })) {
                        HStack {
                            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                            Text(entry.title ?? entry.id).lineLimit(1)
                            Spacer()
                            if let duration = entry.duration {
                                Text(DownloadFormatting.duration(duration)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(height: min(CGFloat(entries.count) * 24 + 8, 170))
        }
    }
}

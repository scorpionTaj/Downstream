import DownstreamCore
import SwiftUI

/// Downstream's "sunset" look: orange → pink → purple, with a color for every download state.
enum Theme {
    static let orange = Color(red: 1.00, green: 0.49, blue: 0.24)
    static let pink = Color(red: 0.96, green: 0.26, blue: 0.50)
    static let purple = Color(red: 0.56, green: 0.27, blue: 0.98)
    static let amber = Color(red: 0.98, green: 0.66, blue: 0.15)
    static let green = Color(red: 0.20, green: 0.75, blue: 0.45)
    static let red = Color(red: 0.95, green: 0.27, blue: 0.23)
    static let indigo = Color(red: 0.42, green: 0.45, blue: 0.95)

    static let sunset = LinearGradient(colors: [orange, pink, purple], startPoint: .leading, endPoint: .trailing)
    static let sunsetDiagonal = LinearGradient(colors: [orange, pink, purple], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Right-to-left when Downstream is running in Arabic. Set explicitly on every scene so the whole
    /// window mirrors, whatever made that language the active one (system setting or launch argument).
    static let layoutDirection: LayoutDirection = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }()

    /// A faint warm wash behind content, the same in light and dark mode.
    static let backdrop = LinearGradient(colors: [orange.opacity(0.07), pink.opacity(0.04), purple.opacity(0.07)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// How a download's state looks: its color, symbol and short name.
struct StatusStyle {
    let color: Color
    let symbol: String
    let title: LocalizedStringKey

    @MainActor
    init(_ state: DownloadJob.State) {
        switch state {
        case .queued: (color, symbol, title) = (Theme.amber, "clock.fill", "Queued")
        case .downloading: (color, symbol, title) = (Theme.pink, "arrow.down.circle.fill", "Downloading")
        case .processing: (color, symbol, title) = (Theme.purple, "wand.and.stars", "Processing")
        case .paused: (color, symbol, title) = (Theme.indigo, "pause.circle.fill", "Paused")
        case .completed: (color, symbol, title) = (Theme.green, "checkmark.circle.fill", "Completed")
        case .failed: (color, symbol, title) = (Theme.red, "exclamationmark.triangle.fill", "Failed")
        case .cancelled: (color, symbol, title) = (.gray, "xmark.circle.fill", "Cancelled")
        }
    }
}

/// A colored rounded square with a white symbol, like the icons in Reminders' lists.
struct IconTile: View {
    let symbol: String
    var fill: AnyShapeStyle = AnyShapeStyle(Theme.sunsetDiagonal)
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small capsule naming a download's state, e.g. "● Downloading".
struct StatusChip: View {
    let style: StatusStyle

    var body: some View {
        Label(style.title, systemImage: style.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// A rounded progress bar filled with the sunset gradient. nil `fraction` shows a moving stripe.
struct SunsetProgressBar: View {
    let fraction: Double?
    var tint: AnyShapeStyle = AnyShapeStyle(Theme.sunset)
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, geometry.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    // Working, but no percentage (starting, converting, embedding, installing): the whole bar is
                    // tinted and a shine sweeps across it. A short stripe used to look like "25% done" in a still moment.
                    // No @State available (Command Line Tools), so the sweep is driven by the clock.
                    Capsule().fill(tint).opacity(0.45)
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let width = max(geometry.size.width * 0.35, 40)
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: width)
                            .offset(x: (geometry.size.width + width) * phase - width)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { String(localized: "\(Int($0 * 100)) percent") } ?? String(localized: "In progress"))
    }
}

/// The main call to action: a capsule filled with the sunset gradient.
struct SunsetButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.pink))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                if prominent {
                    Capsule().fill(Theme.sunset)
                } else {
                    Capsule().fill(Theme.pink.opacity(0.12))
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }
}

/// A round icon button tinted with one color (pause, resume, cancel…).
struct CircleIconButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(configuration.isPressed ? 0.28 : 0.14), in: Circle())
            .contentShape(Circle())
    }
}

extension View {
    /// A raised card: material background, a hairline tinted with `accent`, and a soft shadow.
    func card(accent: Color = .clear, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

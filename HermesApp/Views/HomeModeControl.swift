import SwiftUI

/// The far-right control in Home's 52 pt top bar: a bot glyph on the Sessions screen, the `terminal` glyph on the Bots screen, both icon-only at the hamburger's weight.
enum HomeModeControl {

    /// Tapping the control switches to the other mode; with two modes this is an involution, and a third mode arriving later would break the assumption silently.
    static func toggled(_ mode: AppMode) -> AppMode {
        switch mode {
        case .sessions: return .bots
        case .bots: return .sessions
        }
    }

    /// What the control draws; two cases because one of the two glyphs is not in the SF Symbols catalog.
    enum Glyph: Equatable {
        /// An SF Symbol, resolved by name.
        case symbol(String)
        /// `HermesBotGlyph`, drawn as a path.
        case bot
    }

    /// The glyph names the destination, not the current screen.
    static func glyph(for mode: AppMode) -> Glyph {
        switch mode {
        case .sessions: return .bot
        case .bots: return .symbol("terminal")
        }
    }

    /// What the control is called to VoiceOver and in the button's label. Names the destination, like the glyph.
    static func accessibilityLabel(for mode: AppMode) -> String {
        toggled(mode).label
    }

    /// The glyph box every top-bar icon in this app is drawn in, matching the hamburger's declaration.
    static let glyphSize: CGFloat = 17

    /// BUG-063: 34 pt inside the 44 pt hit box, and a ring rather than a fill so it does not out-shout the composer's send button.
    static let ringDiameter: CGFloat = 34

    /// The ring's weight, visible at a glance without competing with the 17 pt glyph it surrounds.
    static let ringWidth: CGFloat = 2
}

/// The top bar's mode control. 44 pt, `IconButtonStyle`, identical frame in both modes so the two screens' trailing edges line up exactly.
@MainActor
struct HomeModeControlButton: View {
    @Environment(\.hermes) private var t

    /// The mode the current screen is in; the glyph is derived from it.
    let mode: AppMode
    /// Performed on tap; the switch itself is `RootView`'s, which owns `path` and the stashed Sessions path.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // BUG-063: the ring is applied here rather than inside `glyph` so both cases get it from one declaration.
            glyph
                .frame(width: HomeModeControl.ringDiameter, height: HomeModeControl.ringDiameter)
                .overlay(
                    Circle().strokeBorder(t.action, lineWidth: HomeModeControl.ringWidth)
                )
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(HomeModeControl.accessibilityLabel(for: mode))
        .accessibilityHint("Switches between your sessions and your bots")
    }

    @ViewBuilder
    private var glyph: some View {
        switch HomeModeControl.glyph(for: mode) {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: HomeModeControl.glyphSize, weight: .medium))
                .foregroundStyle(t.text1)
        case .bot:
            HermesBotGlyph(size: HomeModeControl.glyphSize, color: t.text1)
        }
    }
}

/// A bot, drawn, because SF Symbols has no robot.
///
/// Every coordinate is a fraction of `size`, so it is the same drawing at the roster's size as at the top bar's.
@MainActor
struct HermesBotGlyph: View {
    var size: CGFloat = HomeModeControl.glyphSize
    var color: Color

    private var stroke: CGFloat { max(1, size / 11) }

    var body: some View {
        ZStack(alignment: .top) {
            // Antenna: a tip dot over a short stem, both reaching the head.
            Circle()
                .fill(color)
                .frame(width: size * 0.15, height: size * 0.15)
            Path { path in
                path.move(to: CGPoint(x: size * 0.5, y: size * 0.13))
                path.addLine(to: CGPoint(x: size * 0.5, y: size * 0.33))
            }
            .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            // Head.
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .stroke(color, lineWidth: stroke)
                .frame(width: size * 0.76, height: size * 0.58)
                .offset(y: size * 0.30)

            // Eyes.
            HStack(spacing: size * 0.20) {
                Circle().fill(color).frame(width: size * 0.11, height: size * 0.11)
                Circle().fill(color).frame(width: size * 0.11, height: size * 0.11)
            }
            .offset(y: size * 0.54)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

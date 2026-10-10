import SwiftUI

/// One rung of the type ladder: a px size at the default content category plus the system text style it scales against, so the app scales with Dynamic Type.
public struct HermesTextStyle: Equatable {
    public let size: CGFloat
    public let weight: Font.Weight
    public let design: Font.Design
    public let relativeTo: Font.TextStyle
    public let width: Font.Width?

    public init(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo: Font.TextStyle,
        width: Font.Width? = nil
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.relativeTo = relativeTo
        self.width = width
    }
}

/// The type ladder; nothing in this app opts out of Dynamic Type.
public enum HermesFont {
    /// Empty-state greeting. One per screen, never two.
    public static let display = HermesTextStyle(size: 28, weight: .semibold, relativeTo: .largeTitle, width: .standard)
    /// Blocking-prompt headline, confirm steps.
    public static let title = HermesTextStyle(size: 20, weight: .semibold, relativeTo: .title2)
    /// Sheet titles.
    public static let heading = HermesTextStyle(size: 17, weight: .semibold, relativeTo: .headline)
    /// Message text. Also the input floor.
    ///
    /// These conversation rungs sit one step under the iOS semantic sizes. Raising them (body 17, callout 16, subheadline 15, footnote 13, FEAT-017 §5) hung the composer when it was first tried (BUG-056). Re-measured later against a real keyboard, the same sizes pass `ComposerReachabilityUITests`, and the composer's chrome measurement is now damped (`ComposerChromeMeasure`), so the composer no longer blocks the change; whether to make it is a design decision. `TypeLadderTests` pins what ships.
    public static let body = HermesTextStyle(size: 16, weight: .regular, relativeTo: .body)
    /// Emphasis inside a message.
    public static let bodyStrong = HermesTextStyle(size: 16, weight: .medium, relativeTo: .body)
    /// List row titles, buttons, provider names.
    public static let callout = HermesTextStyle(size: 15, weight: .regular, relativeTo: .callout)
    public static let calloutStrong = HermesTextStyle(size: 15, weight: .semibold, relativeTo: .callout)
    /// Row descriptions, secondary body.
    public static let subhead = HermesTextStyle(size: 13.5, weight: .regular, relativeTo: .subheadline)
    /// Metadata, timestamps, counters. Always tabular.
    public static let footnote = HermesTextStyle(size: 12, weight: .medium, relativeTo: .footnote)
    /// Section labels, capability chips. Uppercase, 0.08em tracking.
    public static let caption = HermesTextStyle(size: 11, weight: .semibold, relativeTo: .caption2)
    /// Inline code, model ids, paths, the approval command.
    public static let code = HermesTextStyle(size: 13, weight: .regular, design: .monospaced, relativeTo: .footnote)
    public static let codeStrong = HermesTextStyle(size: 13, weight: .semibold, design: .monospaced, relativeTo: .footnote)
    /// Diffs, tool arguments, terminal output.
    public static let codeSmall = HermesTextStyle(size: 12, weight: .regular, design: .monospaced, relativeTo: .caption)

    /// Nothing below 11 px exists in the system.
    public static let floor: CGFloat = 11
}

// MARK: - The scaling overload

/// Backs `View.font(_ style: HermesTextStyle)`: one `@ScaledMetric` unit per text style supplies the factor the rung's px size is multiplied by.
private struct ScaledFontModifier: ViewModifier {
    let style: HermesTextStyle

    @ScaledMetric(relativeTo: .largeTitle) private var largeTitle: CGFloat = 1
    @ScaledMetric(relativeTo: .title) private var title: CGFloat = 1
    @ScaledMetric(relativeTo: .title2) private var title2: CGFloat = 1
    @ScaledMetric(relativeTo: .title3) private var title3: CGFloat = 1
    @ScaledMetric(relativeTo: .headline) private var headline: CGFloat = 1
    @ScaledMetric(relativeTo: .subheadline) private var subheadline: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var body: CGFloat = 1
    @ScaledMetric(relativeTo: .callout) private var callout: CGFloat = 1
    @ScaledMetric(relativeTo: .footnote) private var footnote: CGFloat = 1
    @ScaledMetric(relativeTo: .caption) private var caption: CGFloat = 1
    @ScaledMetric(relativeTo: .caption2) private var caption2: CGFloat = 1

    private var scale: CGFloat {
        switch style.relativeTo {
        case .largeTitle: return largeTitle
        case .title: return title
        case .title2: return title2
        case .title3: return title3
        case .headline: return headline
        case .subheadline: return subheadline
        case .body: return body
        case .callout: return callout
        case .footnote: return footnote
        case .caption: return caption
        case .caption2: return caption2
        @unknown default: return body
        }
    }

    func body(content: Content) -> some View {
        var font = Font.system(size: style.size * scale, weight: style.weight, design: style.design)
        if let width = style.width { font = font.width(width) }
        return content.font(font)
    }
}

public extension View {
    /// Dynamic-Type-relative overload; `HermesTextStyle` is a distinct type from `Font`, so `.font(HermesFont.body)` resolves here.
    func font(_ style: HermesTextStyle) -> some View {
        modifier(ScaledFontModifier(style: style))
    }

    /// Section labels: caption size, uppercase, wide tracking.
    func hermesCaption() -> some View {
        self.font(HermesFont.caption)
            .textCase(.uppercase)
            .tracking(0.9)
    }

    /// Every numeral in a counter, price, token count or countdown, so values do not jitter while they tick.
    func hermesNumeric() -> some View {
        self.monospacedDigit()
    }
}

// MARK: - Enclosure

/// Enclosure is a signal, not a style: a filled, hairlined box means this thing touches your machine.
///
/// Exactly three call sites — tool cards, the approval command block, the sudo and secret fields; a fourth means one of them is wrong.
public struct EnclosureModifier: ViewModifier {
    @Environment(\.hermes) private var t
    @Environment(\.displayScale) private var displayScale

    var tone: Tone = .neutral

    public enum Tone { case neutral, danger, warn }

    /// The ground is the semantic tool-card surface rather than the derived `enclosure`, so a settled tool recedes into the transcript.
    public func body(content: Content) -> some View {
        content
            .background(t.toolCard, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: 1 / displayScale))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
    }

    private var stroke: Color {
        switch tone {
        case .neutral: return t.toolCardStroke
        case .danger: return t.danger.opacity(0.55)
        case .warn: return t.warn.opacity(0.45)
        }
    }
}

public extension View {
    func enclosure(_ tone: EnclosureModifier.Tone = .neutral) -> some View {
        modifier(EnclosureModifier(tone: tone))
    }

    /// The default hairline: one per group boundary, never a border around a panel or between every settings row.
    func hairline(_ edge: Edge = .bottom) -> some View {
        modifier(HairlineModifier(edge: edge))
    }
}

public struct HairlineModifier: ViewModifier {
    @Environment(\.hermes) private var t
    @Environment(\.displayScale) private var displayScale
    let edge: Edge

    public func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            Rectangle()
                .fill(t.stroke3)
                .frame(height: 1 / displayScale)
        }
    }

    private var alignment: Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

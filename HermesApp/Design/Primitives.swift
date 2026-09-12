import SwiftUI
import UIKit

// MARK: - Buttons

/// Primary: action fill, 48 pt for a committing action and 44 pt otherwise, with the pressed scale painted in the current frame rather than animated.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.hermes) private var t
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = Hit.commit

    public init(height: CGFloat = Hit.commit) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HermesFont.calloutStrong)
            .foregroundStyle(isEnabled ? t.actionInk : t.actionInk.opacity(0.45))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                isEnabled ? t.action : t.action.opacity(0.18),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .contentShape(Rectangle())
    }
}

/// Secondary: the default non-primary look, a soft fill-2 ground with a text-1 label and no stroke.
public struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.hermes) private var t
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = Hit.min

    public init(height: CGFloat = Hit.min) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HermesFont.callout)
            .foregroundStyle(isEnabled ? t.text1 : t.text1.opacity(0.4))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                configuration.isPressed ? t.fill3 : t.fill2,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

/// Danger: a danger-fill ground and danger label, never a solid red fill, which is easier to hit accidentally than to read.
public struct DangerButtonStyle: ButtonStyle {
    @Environment(\.hermes) private var t
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = Hit.commit

    public init(height: CGFloat = Hit.commit) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HermesFont.calloutStrong)
            .foregroundStyle(isEnabled ? t.danger : t.danger.opacity(0.45))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                t.dangerFill.opacity(configuration.isPressed ? 1.4 : 1),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

/// Icon: 44 x 44 regardless of glyph size, transparent until pressed, and every icon-only control carries a label.
public struct IconButtonStyle: ButtonStyle {
    @Environment(\.hermes) private var t
    var size: CGFloat = Hit.min

    public init(size: CGFloat = Hit.min) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(
                configuration.isPressed ? t.fill2 : .clear,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Hold to confirm

/// L3 of the destructive ladder: an outline button whose danger fill sweeps in, fires at 100 % and resets if released early.
///
/// Used for delete conversation, rollback restore, always-allow, approval mode `off` and `yolo`, and nothing else.
public struct HoldToConfirmButton: View {
    @Environment(\.hermes) private var t
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    var duration: TimeInterval = 0.8
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isHolding = false
    @State private var didFire = false
    @State private var task: Task<Void, Never>?

    public init(_ title: String, duration: TimeInterval = 0.8, action: @escaping () -> Void) {
        self.title = title
        self.duration = duration
        self.action = action
    }

    public var body: some View {
        ZStack {
            GeometryReader { geo in
                Rectangle()
                    .fill(t.dangerFill)
                    .frame(width: geo.size.width * progress)
            }
            Text(isHolding ? "Hold…" : title)
                .font(HermesFont.callout)
                .foregroundStyle(isEnabled ? t.text1 : t.text3)
        }
        .frame(maxWidth: .infinity, minHeight: Hit.min)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(t.stroke1, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isHolding && !didFire { begin() } }
                .onEnded { _ in
                    didFire = false
                    cancel()
                }
        )
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityHint("Press and hold to confirm")
        .accessibilityAddTraits(.isButton)
        // VoiceOver cannot hold, so a direct activation is offered instead.
        .accessibilityAction { complete() }
    }

    private func begin() {
        isHolding = true
        HapticFeedback.selection()
        if reduceMotion {
            // Discrete quarter steps keep the paint at or behind the elapsed hold, so a full fill never shows before the action fires.
            task = Task { @MainActor in
                for step in 1...4 {
                    try? await Task.sleep(nanoseconds: UInt64(duration / 4 * 1_000_000_000))
                    guard !Task.isCancelled, isHolding else { return }
                    progress = CGFloat(step) / 4
                }
                complete()
            }
        } else {
            withAnimation(.linear(duration: duration)) { progress = 1 }
            task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled, isHolding else { return }
                complete()
            }
        }
    }

    private func complete() {
        // A finger that stays down keeps producing onChanged ticks, so without this latch the destructive action re-fires every `duration` seconds.
        if isHolding { didFire = true }
        isHolding = false
        task?.cancel()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(reduceMotion ? nil : Motion.quick) { progress = 0 }
        action()
    }

    private func cancel() {
        guard isHolding else { return }
        isHolding = false
        task?.cancel()
        withAnimation(reduceMotion ? nil : Motion.quick) { progress = 0 }
    }
}

// MARK: - Rows

/// Plain row, 48 pt minimum: flush left, no per-row background, one bottom hairline, never a card or a rounded group.
public struct FlatRow<Leading: View, Trailing: View>: View {
    @Environment(\.hermes) private var t

    var showsHairline: Bool = true
    var isPressed: Bool = false
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    public init(
        showsHairline: Bool = true,
        isPressed: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.showsHairline = showsHairline
        self.isPressed = isPressed
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Space.s5) {
            leading()
            Spacer(minLength: Space.s4)
            trailing()
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(minHeight: Hit.commit)
        .background(isPressed ? t.fill2 : .clear)
        .modifier(ConditionalHairline(enabled: showsHairline))
        .contentShape(Rectangle())
    }
}

private struct ConditionalHairline: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.hairline() } else { content }
    }
}

// MARK: - Chips

/// Composer pill: a 34 pt visual inside a 44 pt target.
public struct ComposerPill<Content: View>: View {
    @Environment(\.hermes) private var t
    var isInteractive: Bool = true
    let action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    public init(
        isInteractive: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isInteractive = isInteractive
        self.action = action
        self.content = content
    }

    public var body: some View {
        // The 44 pt frame lives on the Button's label: a frame around the Button only centres the rigid pill and leaves the strips above and below inert for hit testing.
        if let action, isInteractive {
            Button(action: action) {
                pill
                    .frame(minHeight: Hit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // Read-only values, not controls: a pill that opens nothing must not look like it opens something.
            pill
                .frame(minHeight: Hit.min)
        }
    }

    private var pill: some View {
        content()
            .font(HermesFont.subhead)
            .foregroundStyle(t.text1)
            .padding(.horizontal, Space.s5)
            .frame(height: 34)
            .background(t.surface2, in: Capsule())
    }
}

/// A four-bar ascending rung showing the quartile of the eight reasoning efforts; the bars are the glanceable read and the name beside them is the exact one.
public struct EffortRung: View {
    @Environment(\.hermes) private var t
    /// 1...8, or nil when unknown.
    let step: Int?

    public init(step: Int?) { self.step = step }

    private var filled: Int {
        guard let step, step > 0 else { return 0 }
        return Int(ceil(Double(min(step, 8)) / 8.0 * 4.0))
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                Capsule()
                    .fill(index <= filled ? t.action : t.text4)
                    .frame(width: 2.5, height: CGFloat(index) * 3 + 1)
            }
        }
        .frame(height: 13, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The eight reasoning efforts, in order; all eight are reachable.
public enum ReasoningEffort: String, CaseIterable, Sendable {
    case off, minimal, low, medium, high, xhigh, max, ultra

    public var step: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// What a person calls it; `off` is spelled out because "off" beside a model name reads as the model being off.
    public var label: String {
        switch self {
        case .off: return "No thinking"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Maximum"
        case .ultra: return "Ultra"
        }
    }

    public init?(backendValue: String) {
        // The backend reports a disabled reasoning config as `"none"`, distinct from `""` (unset), and accepts `off` on the way in.
        let value = backendValue.lowercased()
        self.init(rawValue: value == "none" ? "off" : value)
    }
}

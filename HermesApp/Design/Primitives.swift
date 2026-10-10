import SwiftUI
import UIKit

// MARK: - Buttons

/// Primary: action fill, 48 pt for a committing action and 44 pt otherwise, with the pressed scale painted in the current frame rather than animated. Disabled, it is `controlDisabledInk` on `controlDisabledFill`, like every other disabled control.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.hermes) private var t
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = Hit.commit

    public init(height: CGFloat = Hit.commit) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HermesFont.calloutStrong)
            .foregroundStyle(isEnabled ? t.actionInk : t.controlDisabledInk)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                isEnabled ? t.action : t.controlDisabledFill,
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
            .foregroundStyle(isEnabled ? t.text1 : t.controlDisabledInk)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                !isEnabled ? t.controlDisabledFill : configuration.isPressed ? t.fill3 : t.fill2,
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
            .foregroundStyle(isEnabled ? t.danger : t.controlDisabledInk)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                isEnabled ? t.dangerFill.opacity(configuration.isPressed ? 1.4 : 1) : t.controlDisabledFill,
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

// MARK: - Top bar

extension View {
    /// The one top bar: every pushed screen and every sheet with a navigation bar wears the conversation's own (`chatGlassNavigationBar()` and `chatGlassTopPlane()` in `ChatChrome.swift`), so a change to the conversation's bar is a change to every bar.
    ///
    /// On iOS 26 the bar paints nothing and the screen's scroll view draws the system's soft scroll-edge effect under the glass Back button; below 26 the app's frosted top plane does that job, exactly as on the conversation. It replaces an opaque `t.canvas` bar that eighteen screens painted under the iOS 26 glass Back button, which threw a grey halo on it and made a second bar system beside the conversation's. The screen's own content stays opaque: only the bar is chrome, and words under it are words already scrolled out of reading position, the same contract as the conversation's.
    ///
    /// Apply it to the screen's outermost content, outside any top `safeAreaInset`, so the plane below iOS 26 ends where the bar ends.
    func hermesTopBar() -> some View {
        chatGlassNavigationBar()
            .chatGlassTopPlane()
    }
}

// MARK: - Empty and load-failure states

/// Whether a load failure offers "Try again".
///
/// Only when there is a backend the retry could reach: with none configured it is an action that cannot succeed, and offering it made the screen read as broken rather than as waiting for a connection.
public enum LoadFailureRecovery {
    public static func offersRetry(hasBackend: Bool) -> Bool {
        hasBackend
    }

    /// What a panel says in place of the transport's error when there is no backend to ask.
    public static let noBackendMessage = "Connect a backend to load this."
}

/// The one empty or load-failure state: a glyph, a title, a line of explanation and at most one action, centred in whatever space the screen gives it and standing on the screen's own canvas from edge to edge.
///
/// It replaces a block the backend-backed screens each drew for themselves: a heading, a grey line and a half-width "Try again" pinned to the top-left corner with the rest of the screen empty, and on Capabilities centred in a frame that stopped short of the screen's edges, so dark mode showed black above and below it. Content, not chrome: opaque, never glass.
///
/// It takes all the space it is offered, so mount it where the screen has a height to give (beside a `ScrollView`, not inside one, or under `containerRelativeFrame(.vertical)`).
public struct StatePanel: View {
    @Environment(\.hermes) private var t

    let symbol: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        symbol: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// The disc the glyph sits in: one hit target across, so the panel's mark is the same size as every other round control in the app.
    static let glyphDisc: CGFloat = Hit.min

    /// The panel's text column: wide enough for a two-line explanation, narrow enough that it reads as a note rather than as a page.
    static let columnWidth: CGFloat = 320

    public var body: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: symbol)
                .font(HermesFont.heading)
                .foregroundStyle(t.text3)
                .frame(width: Self.glyphDisc, height: Self.glyphDisc)
                .background(t.fill1, in: Circle())
                .padding(.bottom, Space.s2)
                .accessibilityHidden(true)
            Text(title)
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let message, !message.isEmpty {
                Text(message)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 220)
                    .padding(.top, Space.s4)
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, Space.s8)
        .padding(.vertical, Space.s10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.canvas)
        .accessibilityElement(children: .contain)
    }
}

extension StatePanel {
    /// A screen's failed load: the reason and Try again while there is a backend to ask, and with none a line saying to connect one, with no retry that could only fail again.
    static func loadFailure(title: String, error: String, hasBackend: Bool, retry: @escaping () -> Void) -> StatePanel {
        StatePanel(
            symbol: "exclamationmark.triangle",
            title: title,
            message: hasBackend ? error : LoadFailureRecovery.noBackendMessage,
            actionTitle: "Try again",
            action: LoadFailureRecovery.offersRetry(hasBackend: hasBackend) ? retry : nil
        )
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

/// Plain row, 48 pt minimum: flush left, no per-row background, never a card or a rounded group, and no rule of its own.
///
/// The design system draws one hairline per group boundary and never one between every settings row (`hairline()` in `HermesType.swift`), so a row is unruled unless its caller asks; a rule under every row by default made every list read as a ruled form.
public struct FlatRow<Leading: View, Trailing: View>: View {
    @Environment(\.hermes) private var t

    var showsHairline: Bool = false
    var isPressed: Bool = false
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    public init(
        showsHairline: Bool = false,
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

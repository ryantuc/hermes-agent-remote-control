import SwiftUI

/// The five states every displayed value — a chip, a row value, a meter — can be in.
public enum ValueState: Equatable, Sendable {
    /// Normal.
    case live
    /// The value predates a reconnect; it drops to text-3 but stays interactive and refreshes on reconciliation.
    case stale
    /// The value shows the new setting and an amber dot says it applies at end of turn, from `deferred: true`.
    ///
    /// No producer on iOS yet — its only source is a mid-turn config write; implemented and unused on purpose.
    case pending
    /// No data yet: an em dash, never a spinner or an error, because `session.info` has a lazy variant that returns far fewer fields.
    case unknown
    /// The backend stopped describing this, so the row is removed rather than disabled.
    case unsupported

    /// The common derivation. `lazy` is `SessionInfo.lazy`.
    public static func of(_ value: String, connected: Bool, lazy: Bool) -> ValueState {
        if value.isEmpty { return lazy ? .unknown : .unknown }
        return connected ? .live : .stale
    }
}

/// Applies the five-state treatment to whatever it wraps.
public struct ValueView<Content: View>: View {
    @Environment(\.hermes) private var t

    let state: ValueState
    @ViewBuilder let content: () -> Content

    public init(_ state: ValueState, @ViewBuilder content: @escaping () -> Content) {
        self.state = state
        self.content = content
    }

    public var body: some View {
        switch state {
        case .unsupported:
            // Removed, not disabled: a method this backend lacks is not a fault.
            EmptyView()
        case .unknown:
            Text(verbatim: "—")
                .foregroundStyle(t.text3)
                .accessibilityLabel("Not reported")
        case .live:
            content()
        case .stale:
            content()
                .foregroundStyle(t.text3)
                .accessibilityHint("Last known value; reconnecting")
        case .pending:
            HStack(spacing: Space.s3) {
                Circle()
                    .fill(t.warn)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                content()
            }
            .accessibilityHint("Applies at the end of this turn")
        }
    }
}

public extension View {
    /// Convenience for a value that is already rendered and only needs the treatment layered on.
    func valueState(_ state: ValueState) -> some View {
        ValueView(state) { self }
    }
}

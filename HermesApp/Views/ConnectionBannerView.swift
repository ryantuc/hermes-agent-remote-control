import HermesServeKit
import SwiftUI

/// Connection status strip: one leading semantic dot and one hairline, no tinted panel.
@MainActor
struct ConnectionBannerView: View {
    @Environment(\.hermes) private var t
    /// Read from the environment rather than taken as a parameter, since this view is mounted by three screens; optional so it still stands up with no model in the environment.
    @Environment(AppModel.self) private var app: AppModel?

    let state: GatewayConnectionState
    let detail: String?
    var onRetry: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// The countdown ticks against a wall-clock deadline captured when the reconnecting state lands, not the frozen delay the state carried.
    @State private var reconnectDeadline = Date()

    var body: some View {
        if let presentation = presentation {
            connectionRow(presentation)
        } else if let warning = contractWarning {
            // Only when the socket is open, which falls out of the structure: `presentation` is nil for exactly one state, `.open`.
            contractRow(warning)
        }
    }

    // MARK: BUG-111 — the contract notice

    /// The sentence `AppModel.checkContract` writes, on this strip rather than in Diagnostics, which nobody opens until something has already gone wrong.
    private var contractWarning: String? {
        guard let warning = app?.contractWarning, !warning.isEmpty else { return nil }
        return warning
    }

    private func contractRow(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Circle()
                .fill(t.warn)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .frame(width: 16, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Backend is out of date")
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                Text(warning)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Space.s4)

            // Dismissible, because it is advisory; it does not come back for the same backend.
            action("Dismiss") { app?.dismissContractWarning() }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.canvas)
        .hairline()
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private func connectionRow(_ presentation: Presentation) -> some View {
        HStack(alignment: .top, spacing: Space.s4) {
            leading(presentation)
                .frame(width: 16, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s1) {
                Text(presentation.title)
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                if case .reconnecting = state {
                    countdownSubtitle
                } else if let subtitle = presentation.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Space.s4)

            if presentation.showsSignIn, let onOpenSettings = onOpenSettings {
                action("Sign in", handler: onOpenSettings)
            } else if presentation.showsRetry, let onRetry = onRetry {
                // Retry rides alongside the reconnect spinner, which is safe because every dial funnels through the shared single flight.
                action("Retry", handler: onRetry)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.canvas)
        .hairline()
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .onAppear { captureDeadline() }
        .onChange(of: state) { _, _ in captureDeadline() }
    }

    private func captureDeadline() {
        if case .reconnecting(_, let retryIn) = state {
            reconnectDeadline = Date().addingTimeInterval(retryIn)
        }
    }

    private var countdownSubtitle: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, reconnectDeadline.timeIntervalSince(context.date))
            Text(
                remaining > 0
                    ? "Retrying in \(RelativeTime.countdown(remaining: remaining)). Your agent keeps working on the backend."
                    : "Retrying now. Your agent keeps working on the backend."
            )
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
            .hermesNumeric()
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func leading(_ presentation: Presentation) -> some View {
        if presentation.showsSpinner {
            ProgressView().controlSize(.small)
        } else {
            Circle()
                .fill(presentation.tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
        }
    }

    private func action(_ title: String, handler: @escaping () -> Void) -> some View {
        Button(title, action: handler)
            .font(HermesFont.footnote)
            .foregroundStyle(t.action)
            .padding(.horizontal, Space.s5)
            .frame(minHeight: Hit.min)
            .contentShape(Rectangle())
    }

    private struct Presentation {
        let title: String
        let subtitle: String?
        let tint: Color
        var showsSpinner = false
        var showsSignIn = false
        var showsRetry = false
    }

    private var presentation: Presentation? {
        switch state {
        case .open:
            return nil
        case .idle:
            return Presentation(
                title: "Not connected",
                subtitle: detail ?? "Choose a backend to get started.",
                tint: t.text3,
                showsRetry: true
            )
        case .connecting:
            return Presentation(
                title: "Connecting…",
                subtitle: detail,
                tint: t.text3,
                showsSpinner: true
            )
        case .reconnecting(let attempt, _):
            return Presentation(
                title: "Reconnecting (attempt \(attempt))",
                subtitle: nil,
                tint: t.warn,
                showsSpinner: true,
                showsRetry: true
            )
        case .offline(let reason):
            return Presentation(
                title: "Backend unreachable",
                subtitle: reason,
                tint: t.danger,
                showsRetry: true
            )
        case .unauthorized(let reason):
            return Presentation(
                title: "Sign in again",
                subtitle: reason,
                tint: t.danger,
                showsSignIn: true
            )
        }
    }
}

// MARK: - BUG-111: the contract notice

/// Whether this client should say the backend is too old, and whether it has already been told to stop saying it.
///
/// Per jsonrpc-methods §6.1 the desktop refuses to drive a backend below its required contract version; this client warns instead of refusing.
struct ContractNotice: Equatable {
    /// What to say, or nothing to say.
    private(set) var message: String?
    /// The last sentence the reader waved away.
    private var dismissed: String?

    /// Spelled out because `dismissed` is `private`, which makes the synthesised memberwise initialiser private too.
    init() {}

    /// One `session.info`'s answer; the caller has already established `backendContract` is greater than zero, since zero means the backend did not say.
    mutating func update(backendContract: Int, minimum: Int) {
        guard backendContract < minimum else {
            // The backend is current; clear the dismissal too, since the sentence on the next machine is a different one.
            message = nil
            dismissed = nil
            return
        }
        let warning = "This backend reports contract v\(backendContract); "
            + "this client expects v\(minimum) or newer. Update Hermes Agent."
        guard warning != dismissed else { return }
        message = warning
    }

    mutating func dismiss() {
        dismissed = message
        message = nil
    }
}

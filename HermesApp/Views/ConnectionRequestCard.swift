import AuthenticationServices
import HermesServeKit
import SwiftUI

/// The `manage_connections` card: the agent asked to connect apps and its tool is blocked until the operation settles or the backend's deadline passes (300 s).
///
/// A dock row on the conversation's glass plate, like the notice and error rows: no ground of its own, separated from what follows by a hairline below. The phone offers Sign in on a row with a safe link, Skip on any row the backend lets the user skip, and Continue for the rest; it never approves an install, which runs code on the host. Every row's state is the backend's: answering changes nothing here until `connection.update` arrives.
///
/// Mounted by `ChatView.bottomChromeStack`, above the blocking-prompt bar: `if let connection = model.pendingConnection { ConnectionRequestCard(model: model, request: connection) }`.
@MainActor
struct ConnectionRequestCard: View {
    @Environment(\.hermes) private var t
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let model: ChatModel
    let request: ConnectionRequest
    /// Rows whose sign-in sheet the person has opened, so a pending row reads "waiting" rather than idle.
    @State private var opened: Set<String> = []
    @State private var signingIn: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s4) {
                Circle().fill(t.warn).frame(width: 8, height: 8)
                Text(request.targets.count == 1 ? "Hermes wants to connect an app" : "Hermes wants to connect apps")
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                Spacer(minLength: Space.s4)
                if let deadline = request.deadlineAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, deadline.timeIntervalSince(context.date))
                        Text(RelativeTime.countdown(remaining: remaining))
                            .font(HermesFont.footnote)
                            .hermesNumeric()
                            .foregroundStyle(remaining < 30 ? t.danger : t.warn)
                            .accessibilityLabel("Time left to answer")
                    }
                }
            }
            ForEach(request.targets) { target in
                row(target)
            }
            if !request.unresolvedTargets.isEmpty {
                Button {
                    model.continueConnection()
                } label: {
                    Text("Continue without the rest")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.action)
                        .frame(minHeight: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isAnsweringConnection)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.bottom)
        .id(request.opID)
    }

    private func row(_ target: ConnectionTarget) -> some View {
        HStack(spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(target.title)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                Text(stateLabel(target))
                    .font(HermesFont.footnote)
                    .foregroundStyle(target.state == "connected" ? t.ok : t.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: Space.s4)
            if target.canOpen, let url = target.connectURL {
                rowButton(signingIn == target.name ? "Signing in…" : "Sign in") {
                    Task { await signIn(target, url: url) }
                }
                .disabled(signingIn != nil)
            }
            if target.canSkip {
                rowButton("Skip") { model.skipConnectionTarget(target.name) }
                    .disabled(model.isAnsweringConnection)
            }
        }
        .frame(minHeight: Hit.min)
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(HermesFont.footnote)
                .foregroundStyle(t.action)
                .padding(.horizontal, Space.s2)
                .frame(minWidth: Hit.min, minHeight: Hit.min)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The backend's state in words; an unknown state is shown as it arrived rather than guessed at.
    private func stateLabel(_ target: ConnectionTarget) -> String {
        switch target.state {
        case "connected": return "Connected"
        case "skipped": return "Skipped"
        case "initiated": return opened.contains(target.name) ? "Waiting for the sign-in to finish" : "Sign-in started"
        case "pending":
            if target.connectURL != nil { return opened.contains(target.name) ? "Waiting for the sign-in to finish" : "Not connected" }
            return target.detail.isEmpty ? "Needs setup on the computer running Hermes" : target.detail
        case "failed": return target.detail.isEmpty ? "Sign-in failed" : target.detail
        case "expired": return "The sign-in link expired"
        case "not_connected": return "Not connected"
        default: return target.state
        }
    }

    /// The sign-in leg ends at `hermes://connections/done` (`tools/connectors/gateway/wire.py:142`), which this app's own scheme hands back to the session; closing the sheet returns too. Either way the backend's watcher decides whether the account connected, and the wake only shortens its wait.
    private func signIn(_ target: ConnectionTarget, url: URL) async {
        signingIn = target.name
        opened.insert(target.name)
        defer { signingIn = nil }
        _ = try? await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "hermes")
        model.wakeConnection()
    }
}

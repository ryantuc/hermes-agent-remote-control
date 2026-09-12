import HermesServeKit
import SwiftUI

/// What the composer's effort pill opens: all eight `ReasoningEffort` levels, in order, one tap from the composer.
///
/// A live session needs its session id for `config.set`, because a session-less write lands on the backend's global default for every client; a draft adjusts locally and the choice rides `session.create`.
@MainActor
struct EffortSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let model: ChatModel

    @State private var busy: ReasoningEffort?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // The write-failure slot lives outside the scroll content.
            if let failure {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s4)
                    .accessibilityAddTraits(.isStaticText)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                        row(effort)
                    }
                }
                .padding(.bottom, Space.s10)
            }
        }
        .background(t.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Text("Reasoning effort")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.text3)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s6)
        .padding(.bottom, Space.s4)
    }

    /// The display label, and the value the backend actually stores beneath it.
    private func row(_ effort: ReasoningEffort) -> some View {
        Button {
            Task { await select(effort) }
        } label: {
            FlatRow(showsHairline: false) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(effort.label)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    Text(effort.rawValue)
                        .font(HermesFont.code)
                        .foregroundStyle(t.text3)
                }
            } trailing: {
                if busy == effort {
                    ProgressView().controlSize(.small)
                } else if isCurrent(effort) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(t.action)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityLabel("\(effort.label)\(isCurrent(effort) ? ", selected" : "")")
    }

    private var current: String {
        if let info = model.info { return info.reasoningEffort }
        if model.isDraft { return model.draftEffort ?? app.defaultEffort }
        return ""
    }

    /// Compared as a value, not as a string: the backend spells a disabled config `none` where the client writes `off`.
    private func isCurrent(_ effort: ReasoningEffort) -> Bool {
        ReasoningEffort(backendValue: current) == effort
    }

    private func select(_ effort: ReasoningEffort) async {
        // Draft: local paint, carried into `session.create`.
        if model.isDraft {
            model.draftEffort = effort.rawValue
            dismiss()
            return
        }
        guard let configAPI = app.configAPI else {
            failure = "Not connected to a backend."
            return
        }
        // `scope: "session"` is not self-enforcing: with no session id the backend writes its global default instead.
        guard let sessionID = model.runtimeSessionID else {
            failure = "This conversation has no session yet. Send a message first, then set the effort."
            return
        }
        failure = nil
        busy = effort
        defer { busy = nil }
        do {
            let result = try await configAPI.set(
                "reasoning",
                value: .string(effort.rawValue),
                sessionID: sessionID,
                scope: "session"
            )
            // A write during a running turn comes back `deferred: true`, so the pill stays pending until the next `session.info`.
            if result.deferred { model.pendingEffortWrite = true }
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

import HermesServeKit
import SwiftUI

/// Edit & resend: while the composer holds an earlier message being edited, say so and offer the way out. Send replaces that message and everything after it (`ChatModel.sendEdit`, `prompt.submit` with `truncate_before_row_id`).
///
/// A dock row on the conversation's glass plate like the notice and error rows: no ground of its own, a hairline below.
///
/// Mounted by `ChatView.bottomChromeStack`, directly above the composer: `if model.editingEntryID != nil { EditingMessageBanner(model: model) }`.
@MainActor
struct EditingMessageBanner: View {
    @Environment(\.hermes) private var t
    let model: ChatModel

    var body: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "pencil")
                .font(.system(size: 13))
                .foregroundStyle(t.text3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Editing an earlier message")
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                Text("Sending replaces it and everything after it.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            Spacer(minLength: Space.s4)
            Button {
                model.cancelEditing()
            } label: {
                Text("Cancel")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.action)
                    .frame(minWidth: Hit.min, minHeight: Hit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.bottom)
    }
}

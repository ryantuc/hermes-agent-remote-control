import SwiftUI

/// Home's draft error line, above its composer: the same row a conversation shows above its own, so a command refused on Home is read where it was typed, with Send as text beside it while the kept draft would run as a command again.
@MainActor
struct HomeErrorRow: View {
    @Environment(\.hermes) private var t
    let message: String
    var sendAsText: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Circle().fill(t.danger).frame(width: 8, height: 8).padding(.top, 5)
                .accessibilityHidden(true)
            Text(message)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sendAsText {
                Button(action: sendAsText) {
                    Text("Send as text")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.action)
                        .padding(.top, Space.s1)
                        .frame(minHeight: Hit.min, alignment: .top)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

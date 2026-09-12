import SwiftUI

/// Settings → Chat → Composer actions: which quick actions the
/// `+` sheet shows, and in what order. The three tiles are fixed and are not
/// listed here. Reordering is explicit up/down buttons — drag-to-reorder
/// needs a `List`, and Settings is flat rows, never a table.
@MainActor
struct ComposerActionsSettingsView: View {
    @Environment(\.hermes) private var t

    @State private var enabled = ComposerQuickAction.enabled

    private var available: [ComposerQuickAction] {
        ComposerQuickAction.allCases.filter { !enabled.contains($0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Shown in the + sheet")
                    .padding(.top, Space.s6)
                if enabled.isEmpty {
                    Text("Nothing yet — the + sheet shows only the three tiles.")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .padding(Space.s6)
                }
                ForEach(Array(enabled.enumerated()), id: \.element) { index, action in
                    FlatRow {
                        Text(action.label)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                    } trailing: {
                        HStack(spacing: 0) {
                            arrowButton("chevron.up", enabled: index > 0, label: "Move \(action.label) up") {
                                enabled.swapAt(index, index - 1)
                                persist()
                            }
                            arrowButton("chevron.down", enabled: index < enabled.count - 1, label: "Move \(action.label) down") {
                                enabled.swapAt(index, index + 1)
                                persist()
                            }
                            arrowButton("minus.circle", enabled: true, label: "Remove \(action.label)") {
                                enabled.removeAll { $0 == action }
                                persist()
                            }
                        }
                    }
                }

                if !available.isEmpty {
                    SectionHeader("Available")
                        .padding(.top, Space.s8)
                    ForEach(available) { action in
                        Button {
                            enabled.append(action)
                            persist()
                            HapticFeedback.selection()
                        } label: {
                            FlatRow {
                                Text(action.label)
                                    .font(HermesFont.callout)
                                    .foregroundStyle(t.text1)
                            } trailing: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(t.action)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(action.label)")
                    }
                }
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Composer actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
    }

    private func arrowButton(_ icon: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(enabled ? t.text2 : t.text4.opacity(0.4))
                .frame(width: Hit.min, height: Hit.min)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func persist() {
        ComposerQuickAction.enabled = enabled
    }
}

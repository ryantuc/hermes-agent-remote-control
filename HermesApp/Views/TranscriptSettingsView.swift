import SwiftUI

/// Settings → Chat → Transcript. All
/// client-local display preferences — the rows repaint the transcript, not
/// the agent. Autoplay is deliberately absent: the media contract forbids
/// autoplay outright ("never autoplay, never muted-autoplay"), and a switch
/// that could contradict it would weaken the rule.
@MainActor
struct TranscriptSettingsView: View {
    @Environment(\.hermes) private var t

    // Local mirrors so the rows repaint in the frame of the tap; the statics
    // persist through UserDefaults.
    @State private var toolsExpanded = TranscriptPreferences.toolCardsExpandByDefault
    @State private var groupCalls = TranscriptPreferences.groupRepeatedCalls
    @State private var showDiffs = TranscriptPreferences.showDiffs
    @State private var actionBranch = TranscriptPreferences.showBranchAction
    @State private var actionCopy = TranscriptPreferences.showCopyAction
    @State private var actionReadAloud = TranscriptPreferences.showReadAloudAction
    @State private var actionRetry = TranscriptPreferences.showRetryAction

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Tool calls")
                    .padding(.top, Space.s6)

                VStack(alignment: .leading, spacing: Space.s3) {
                    Text("Default state")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    SegmentedRow(
                        options: [false, true],
                        selection: Binding(
                            get: { toolsExpanded },
                            set: { newValue in
                                toolsExpanded = newValue
                                TranscriptPreferences.toolCardsExpandByDefault = newValue
                            }
                        ),
                        label: { $0 ? "Expanded" : "Collapsed" }
                    )
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)
                .hairline()

                SwitchRow(
                    "Group repeated calls",
                    subtitle: "Consecutive calls of the same tool collapse into one ×N row.",
                    isOn: Binding(
                        get: { groupCalls },
                        set: { newValue in
                            groupCalls = newValue
                            TranscriptPreferences.groupRepeatedCalls = newValue
                        }
                    )
                )
                SwitchRow(
                    "Show diffs for edits",
                    isOn: Binding(
                        get: { showDiffs },
                        set: { newValue in
                            showDiffs = newValue
                            TranscriptPreferences.showDiffs = newValue
                        }
                    )
                )

                SectionHeader("Message actions")
                    .padding(.top, Space.s8)

                SwitchRow("Branch", isOn: Binding(
                    get: { actionBranch },
                    set: { actionBranch = $0; TranscriptPreferences.showBranchAction = $0 }
                ))
                SwitchRow("Copy", isOn: Binding(
                    get: { actionCopy },
                    set: { actionCopy = $0; TranscriptPreferences.showCopyAction = $0 }
                ))
                SwitchRow("Read aloud", isOn: Binding(
                    get: { actionReadAloud },
                    set: { actionReadAloud = $0; TranscriptPreferences.showReadAloudAction = $0 }
                ))
                SwitchRow("Retry", isOn: Binding(
                    get: { actionRetry },
                    set: { actionRetry = $0; TranscriptPreferences.showRetryAction = $0 }
                ))
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
    }
}

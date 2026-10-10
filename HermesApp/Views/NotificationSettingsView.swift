import ActivityKit
import HermesServeKit
import SwiftUI

/// Settings → Device → Notifications (FEAT-019), every row of it client-local.
///
/// ActivityKit does not offer two activities — one `Activity.request` drives both presentations — so the two surface switches are a presentation split; see `LiveActivitySurfaces`.
@MainActor
struct NotificationSettingsView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @State private var enabled = LiveActivityPreferences.enabled
    @State private var cron = LiveActivityPreferences.autoStartForCron
    @State private var lockScreen = LiveActivityPreferences.lockScreen
    @State private var island = LiveActivityPreferences.island
    @State private var showPolicy = LiveActivityPreferences.showPolicy
    @State private var rosterOpen = false
    /// Recomputed on appear and whenever the sheet closes: the system switch lives in iOS Settings and can change while we are backgrounded.
    @State private var systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Live Activities")
                    .padding(.top, Space.settingsTop)

                SwitchRow(
                    "Live Activities",
                    subtitle: systemAllows
                        ? "A running chat shows its current tool and elapsed time on the Lock Screen and in the Dynamic Island. Off means neither, straight away."
                        : NotificationSettingsCopy.systemOff,
                    isOn: Binding(
                        get: { enabled && systemAllows },
                        set: { newValue in
                            enabled = newValue
                            // Off means off now, not at the end of the turn.
                            LiveActivitySettingsActions.setMaster(newValue)
                        }
                    )
                )
                .disabled(!systemAllows)

                SwitchRow(
                    "On the Lock Screen",
                    subtitle: "Off shows only the app name and one word on the Lock Screen. iOS keeps that small card while the Dynamic Island is on.",
                    isOn: Binding(
                        get: { lockScreen },
                        set: { newValue in
                            lockScreen = newValue
                            LiveActivitySettingsActions.setLockScreen(newValue)
                        }
                    )
                )
                .disabled(!enabled || !systemAllows)

                SwitchRow(
                    "In the Dynamic Island",
                    subtitle: "Off leaves the Dynamic Island empty. iOS may still show a blank pill while a Lock Screen card is up.",
                    isOn: Binding(
                        get: { island },
                        set: { newValue in
                            island = newValue
                            LiveActivitySettingsActions.setIsland(newValue)
                        }
                    )
                )
                .disabled(!enabled || !systemAllows)

                Text("Turning both of these off is the same as turning Live Activities off: no card is started at all.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s5)

                SectionHeader("Show a card for")
                    .padding(.top, Space.s7)

                SegmentedRow(
                    options: LiveActivityShowPolicy.allCases,
                    selection: Binding(
                        get: { showPolicy },
                        set: { newValue in
                            showPolicy = newValue
                            LiveActivitySettingsActions.setShowPolicy(newValue)
                        }
                    )
                ) { $0.label }
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s5)
                .disabled(!enabled || !systemAllows)

                Text(showPolicyExplanation)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)

                SectionHeader("Chats")
                    .padding(.top, Space.s7)

                rosterRow

                SwitchRow(
                    "Start for scheduled runs",
                    subtitle: "Scheduled runs get a card too, since nobody is watching them. Off: only chats you opened on this iPhone get one.",
                    isOn: Binding(
                        get: { cron },
                        set: { newValue in
                            cron = newValue
                            LiveActivitySettingsActions.setAutoStartForCron(newValue)
                        }
                    )
                )
                .disabled(!enabled || !systemAllows)

                Text("The command itself never appears on the Lock Screen. It shows inside HARC and, when it is short enough to read whole, in the expanded Dynamic Island. Approving there still asks for Face ID.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s5)

                SectionHeader("Notifications")
                    .padding(.top, Space.s8)

                Text(NotificationSettingsCopy.notifications)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s4)
                    .padding(.bottom, Space.s9)
            }
        }
        .background(t.canvas.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled }
        .sheet(isPresented: $rosterOpen) {
            LiveActivityRosterSheet()
                .onDisappear { systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled }
        }
    }

    /// The when-to-show row in words; a blocked turn always earns a card under either setting.
    private var showPolicyExplanation: String {
        switch showPolicy {
        case .everyTurn:
            return "Every turn that runs gets a card, and so does every question Hermes stops to ask you."
        case .questionsOnly:
            return "Nothing appears for a turn that is simply running. When Hermes stops to ask you something, you get a card if HARC is on screen at that moment, and a notification if it is not."
        }
    }

    private var rosterRow: some View {
        Button {
            rosterOpen = true
        } label: {
            FlatRow {
                Text("Chats on Lock Screen")
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
            } trailing: {
                HStack(spacing: Space.s3) {
                    Text(NotificationSettingsCopy.rosterValue(active: LiveActivityController.shared.activeCount, cap: LiveActivityRoster.cap))
                        .font(HermesFont.subhead)
                        .hermesNumeric()
                        .foregroundStyle(t.text3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.text4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled || !systemAllows)
        .accessibilityLabel("Chats on Lock Screen, \(NotificationSettingsCopy.rosterValue(active: LiveActivityController.shared.activeCount, cap: LiveActivityRoster.cap))")
    }
}

/// The screen's longer sentences, kept where a test can read them. The app is HARC on the Home Screen and in iOS Settings, so the words that send a person there use that name.
enum NotificationSettingsCopy {
    static let systemOff = "Turned off in iOS Settings → HARC → Live Activities. Nothing appears until it is turned back on there."

    static let notifications = "HARC notifies you when Hermes stops to ask you something (an approval, a question, a password) and the app is not on screen. The notification says only which kind of answer is needed: never the command, the question, the value or the chat's name. There is no push service: the notification comes from HARC itself, so it arrives only while HARC is running. If HARC is closed, or iOS has put it to sleep in the background, nothing reaches you until you open it again."

    /// "None" rather than "0 of 2", which read like a quota.
    static func rosterValue(active: Int, cap: Int) -> String {
        active == 0 ? "None" : "\(active) of \(cap)"
    }
}

/// The roster: it fills itself, so what a person needs here is to see what is on their Lock Screen and be able to take one off it.
@MainActor
struct LiveActivityRosterSheet: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var rows: [LiveActivityController.RosterRow] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("No chats on the Lock Screen right now.")
                            .font(HermesFont.body)
                            .foregroundStyle(t.text2)
                            .padding(.horizontal, Space.s6)
                            .padding(.top, Space.s9)
                        Text("A chat appears here while a turn is running, and leaves when the turn ends. Up to \(LiveActivityRoster.cap) at once — a third pushes the oldest off.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Space.s6)
                            .padding(.top, Space.s5)
                    } else {
                        ForEach(rows) { row in
                            FlatRow {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title)
                                        .font(HermesFont.callout)
                                        .foregroundStyle(t.text1)
                                        .lineLimit(1)
                                    Text(row.detail)
                                        .font(HermesFont.footnote)
                                        .foregroundStyle(t.text3)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } trailing: {
                                Button("Take off") {
                                    LiveActivityController.shared.dismiss(sessionID: row.id)
                                    refresh()
                                }
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.action)
                                .frame(minHeight: Hit.min)
                            }
                        }
                    }
                }
            }
            .background(t.canvas.ignoresSafeArea())
            .navigationTitle("Chats on Lock Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        rows = LiveActivityController.shared.rosterRows()
    }
}

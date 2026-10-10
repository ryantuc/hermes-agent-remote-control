import HermesServeKit
import SwiftUI

/// Settings → Device → Voice: the engine and its behaviour are device choices that live in UserDefaults and never touch the wire, while the provider rows underneath are the backend's `stt.provider` / `tts.provider`, read-only here.
/// A key the gateway does not report reads `Auto` (BUG-042), because unset is a real, common state of these two keys and dropping the row would say something false about the backend.
@MainActor
struct VoiceSettingsView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    @State private var engine = VoicePreferences.engine
    @State private var insertLive = VoicePreferences.insertAsYouSpeak
    @State private var tapToToggle = VoicePreferences.tapToToggle
    @State private var speakReplies = VoicePreferences.speakReplies

    private var store: SettingsStore { app.settings }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Dictation")
                    .padding(.top, Space.settingsTop)

                VStack(alignment: .leading, spacing: Space.s3) {
                    Text("Engine")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    SegmentedRow(
                        options: DictationEngine.allCases,
                        selection: Binding(
                            get: { engine },
                            set: { newValue in
                                engine = newValue
                                VoicePreferences.engine = newValue
                            }
                        ),
                        label: { $0.label }
                    )
                    Text(engineNote)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)
                .hairline()

                SwitchRow(
                    "Insert as you speak",
                    subtitle: engine.supportsPartialResults
                        ? "Words land in the draft as you say them."
                        : "Only the on-device engine can do this — the Hermes engine transcribes the whole recording at once.",
                    isOn: Binding(
                        get: { insertLive && engine.supportsPartialResults },
                        set: { newValue in
                            insertLive = newValue
                            VoicePreferences.insertAsYouSpeak = newValue
                        }
                    )
                )
                // Disabled, not hidden: the row explains why it cannot do anything here, which a missing row could not.
                .disabled(!engine.supportsPartialResults)
                .opacity(engine.supportsPartialResults ? 1 : 0.5)

                VStack(alignment: .leading, spacing: Space.s3) {
                    Text("Microphone button")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    SegmentedRow(
                        options: [false, true],
                        selection: Binding(
                            get: { tapToToggle },
                            set: { newValue in
                                tapToToggle = newValue
                                VoicePreferences.tapToToggle = newValue
                            }
                        ),
                        label: { $0 ? "Tap to toggle" : "Press and hold" }
                    )
                    Text("Press and hold cannot leave the microphone open by accident. Tap to toggle is easier for a long dictation.")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.s6)
                .padding(.vertical, Space.s4)
                .hairline()

                SectionHeader("Voice chat")
                    .padding(.top, Space.s8)

                SwitchRow(
                    "Speak replies",
                    subtitle: "Reads answers aloud with the device voice. Off makes voice chat listen-only.",
                    isOn: Binding(
                        get: { speakReplies },
                        set: { newValue in
                            speakReplies = newValue
                            VoicePreferences.speakReplies = newValue
                        }
                    )
                )

                Text("Voice chat always uses on-device recognition, so it can hear when you start and stop talking.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.vertical, Space.s5)

                SectionHeader("On the backend")
                    .padding(.top, Space.s8)

                providerRow("Speech to text", key: "stt.provider")
                providerRow("Text to speech", key: "tts.provider")

                Text("The Hermes engine uses the speech-to-text provider set on your computer. Reading answers aloud always uses this iPhone's voice.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.vertical, Space.s5)
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .hermesTopBar()
        .task { await store.loadIfNeeded() }
    }

    private var engineNote: String {
        switch engine {
        case .onDevice:
            return "Runs on this iPhone. Nothing is uploaded, it starts instantly, and it is the only engine that can insert words as you speak."
        case .hermes:
            return "Uploads the recording to your backend so the transcript matches what the desktop would produce. It arrives only after you stop talking."
        }
    }

    /// A backend value, through `ValueView`.
    /// BUG-042: an unreported key no longer removes this row, since absent is the normal state of a backend nobody has pinned, but an unloaded document still renders nothing.
    @ViewBuilder
    private func providerRow(_ label: String, key: String) -> some View {
        if let document = store.document {
            FlatRow {
                Text(label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
            } trailing: {
                ValueView(app.connectionState.isOpen ? .live : .stale) {
                    Text(BackendProviderLabel.text(at: key, in: document))
                        .font(HermesFont.code)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The trailing text of the "On the backend" provider rows.
enum BackendProviderLabel {
    /// What an unset provider reads as: not "None" and not blank, because the backend picks one when it has not been told which engine to use.
    static let unset = "Auto"

    static func text(at key: String, in document: JSONValue) -> String {
        let raw = ConfigDocument.value(at: key, in: document)?.coercedString ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? unset : trimmed
    }
}

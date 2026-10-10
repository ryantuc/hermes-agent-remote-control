import HermesServeKit
import SwiftUI

/// Hands-free voice chat: the waveform is the only chrome and a single Done ends it, so there is no transcript, no send button, no model pill and no settings here.
/// BUG-140 makes recognition half-duplex: the audio engine keeps the route stable, but buffers reach Speech only during listening, so the phone's own speaker output cannot manufacture a user turn.
/// Speech out is the device synthesiser, reusing `ReadAloud`; `/api/audio/speak` is deliberately not used, being a round trip and a provider bill for something the phone does instantly and offline.
@MainActor
struct VoiceChatView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var model: ChatModel

    @State private var session = VoiceChatSession()

    var body: some View {
        ZStack {
            t.canvas.ignoresSafeArea()

            VStack(spacing: Space.s8) {
                Spacer()

                Waveform(level: session.level, phase: session.phase)
                    .frame(height: 120)
                    .padding(.horizontal, Space.s8)
                    .accessibilityHidden(true)

                // The one line of text: a state label, not a transcript, so a glance tells you whose turn it is.
                Text(session.phase.label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text3)
                    .contentTransition(.opacity)
                    .animation(Motion.quick, value: session.phase)
                    .accessibilityLabel(session.phase.accessibilityLabel)

                if let failure = session.failure {
                    Text(failure)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.s8)
                }

                Spacer()

                Button {
                    session.end()
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Space.s8)
                .padding(.bottom, Space.s8)
                .accessibilityLabel("End voice chat")
            }
        }
        .task { session.begin(model: model, app: app) }
        .onDisappear { session.end() }
        // `.inactive` is deliberately excluded: it covers transient UI such as the app switcher and notification centre, not leaving the app.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            // BUG-071 B's ruling ends the conversation on leaving the app; a running one says so on return instead of reading Starting….
            if session.phase.isRunning {
                session.stop(reason: "Voice chat ended when you left HARC. Tap Done and start it again.")
            } else {
                session.end()
            }
        }
    }
}

// MARK: - The waveform

/// The only chrome: bars driven by the live input level while listening, by a slow idle breath while thinking, and by the synthesiser's own activity while speaking.
private struct Waveform: View {
    @Environment(\.hermes) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let level: Double
    let phase: VoiceChatSession.Phase

    private let bars = 27

    var body: some View {
        Canvas { context, size in
            let width = size.width / Double(bars * 2 - 1)
            for index in 0..<bars {
                let height = max(4, size.height * amplitude(at: index))
                let x = Double(index) * width * 2
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(tint)
                )
            }
        }
        .animation(reduceMotion ? nil : Motion.quick, value: level)
        .animation(reduceMotion ? nil : Motion.quick, value: phase)
    }

    private var tint: Color {
        switch phase {
        case .listening: return t.action
        case .thinking: return t.text4
        case .speaking: return t.accent
        case .idle, .stopped: return t.text4
        }
    }

    /// A fixed symmetric envelope scaled by the live level, deterministic because a random walk reads as noise and defeats the point of showing that the mic is hearing you.
    private func amplitude(at index: Int) -> Double {
        let centre = Double(bars - 1) / 2
        let distance = abs(Double(index) - centre) / centre
        let envelope = 1 - distance * distance
        switch phase {
        case .listening:
            return 0.06 + 0.94 * envelope * max(level, 0.02)
        case .speaking:
            return 0.10 + 0.55 * envelope
        case .thinking:
            return 0.06 + 0.10 * envelope
        case .idle, .stopped:
            return 0.05
        }
    }
}

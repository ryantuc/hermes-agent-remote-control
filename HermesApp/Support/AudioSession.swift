import AVFoundation
import Observation

/// The one place that owns `AVAudioSession` (band 7d): uses are reference
/// counted, the category derives from whichever uses are live, and the session
/// is deactivated only when the last one ends. `.defaultToSpeaker` is set
/// explicitly because `.playAndRecord` routes output to the earpiece and
/// `.voiceChat` mode does not imply it; `.allowBluetoothHFP` is the deprecated
/// `.allowBluetooth` under its current name, available back to iOS 1.0.
@MainActor
@Observable
final class AudioSession {
    static let shared = AudioSession()

    enum Use: Hashable {
        case readAloud
        case dictation
        case voiceChat
    }

    private(set) var active: Set<Use> = []

    /// Called when the system interrupts us. One slot is enough because only one
    /// recording use can be live at a time.
    var interruptionHandler: (@MainActor () -> Void)?

    private var observing = false

    private init() {}

    /// Claim the session for `use`, reconfiguring only if the category changes.
    func begin(_ use: Use) throws {
        observeInterruptionsIfNeeded()
        let before = configuration(for: active)
        active.insert(use)
        let after = configuration(for: active)

        let session = AVAudioSession.sharedInstance()
        if before == nil || after != before {
            guard let after else { return }
            try session.setCategory(after.category, mode: after.mode, options: after.options)
        }
        try session.setActive(true)
    }

    /// Release `use`. Deactivates only when nothing is left holding the session,
    /// and steps back down to a weaker category when something is.
    func end(_ use: Use) {
        guard active.contains(use) else { return }
        let before = configuration(for: active)
        active.remove(use)
        let after = configuration(for: active)

        let session = AVAudioSession.sharedInstance()
        guard let after else {
            // `.notifyOthersOnDeactivation` lets whatever we ducked come back up.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        if after != before {
            try? session.setCategory(after.category, mode: after.mode, options: after.options)
        }
    }

    /// Belt and braces for a torn-down surface: drop everything at once.
    func endAll() {
        active.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Category derivation

    private struct Configuration: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    /// Strongest requirement wins. Ordering matters: with both a read-aloud and
    /// a live mic, only `.playAndRecord` satisfies both.
    private func configuration(for uses: Set<Use>) -> Configuration? {
        if uses.contains(.voiceChat) {
            return Configuration(
                category: .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
            )
        }
        if uses.contains(.dictation) {
            return Configuration(category: .record, mode: .measurement, options: [.duckOthers])
        }
        if uses.contains(.readAloud) {
            return Configuration(category: .playback, mode: .default, options: [.duckOthers])
        }
        return nil
    }

    // MARK: Interruptions

    private func observeInterruptionsIfNeeded() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            // Hop to the actor rather than touching state from the delivering queue.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                // We do not auto-resume on `.ended`: a dictation that restarts
                // itself after a phone call is a hot mic nobody asked for.
                AudioSession.shared.interruptionHandler?()
            }
        }
    }
}

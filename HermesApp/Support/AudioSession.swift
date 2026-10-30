import AVFoundation
import Observation

/// The one place that owns `AVAudioSession`: uses are reference
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

    /// A change to the audio route that a live microphone cannot ride out (BUG-131 B). The system's other reasons — a category change, which our own `begin` causes, a configuration change, waking from sleep — leave the devices where they were and are not reported.
    enum RouteChange: Equatable {
        /// A headset, AirPods or a car left the route.
        case deviceLost
        /// A headset, AirPods or a car joined the route.
        case deviceAdded
        /// Nothing on the route can serve the category, such as no microphone.
        case noRoute

        init?(reason: AVAudioSession.RouteChangeReason) {
            switch reason {
            case .oldDeviceUnavailable: self = .deviceLost
            case .newDeviceAvailable: self = .deviceAdded
            case .noSuitableRouteForCategory: self = .noRoute
            default: return nil
            }
        }
    }

    private(set) var active: Set<Use> = []

    /// Called when the system interrupts us. One slot is enough because only one
    /// recording use can be live at a time.
    var interruptionHandler: (@MainActor () -> Void)?

    /// Called when a device joins or leaves the route. One slot, for the same reason as `interruptionHandler`; only voice chat installs it.
    var routeChangeHandler: (@MainActor (RouteChange) -> Void)?

    private var observing = false

    private init() {}

    /// Claim the session for `use`, reconfiguring only if the category changes.
    ///
    /// The use is recorded before the session is touched, so it is held even when this throws: the caller ends what it began on every path, failure included, and every caller's failure path does.
    func begin(_ use: Use) throws {
        observeSystemNotificationsIfNeeded()
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

    // MARK: Interruptions and route changes

    private func observeSystemNotificationsIfNeeded() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let raw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      let change = RouteChange(reason: reason)
                else { return }
                AudioSession.shared.routeChangeHandler?(change)
            }
        }
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

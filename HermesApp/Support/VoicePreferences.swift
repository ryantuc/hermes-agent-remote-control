import Foundation
import HermesServeKit

/// Client-local voice preferences: these are device choices, not agent config, so they live in UserDefaults and never touch the wire.
enum VoicePreferences {
    private static let defaults = UserDefaults.standard

    /// On-device by default: it wins on latency and loses nothing on this app's vocabulary.
    static var engine: DictationEngine {
        get {
            guard let raw = defaults.string(forKey: "hermes.voice.engine"),
                  let engine = DictationEngine(rawValue: raw)
            else { return .onDevice }
            return engine
        }
        set { defaults.set(newValue.rawValue, forKey: "hermes.voice.engine") }
    }

    /// Live partial results land in the draft as they arrive; only `.onDevice` streams, so the row is disabled rather than quietly ignored on `.hermes`.
    static var insertAsYouSpeak: Bool {
        get { defaults.object(forKey: "hermes.voice.insertLive") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hermes.voice.insertLive") }
    }

    /// Tap to toggle rather than press and hold; hold is the default because it cannot leave a hot mic behind.
    static var tapToToggle: Bool {
        get { defaults.object(forKey: "hermes.voice.tapToggle") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hermes.voice.tapToggle") }
    }

    /// Voice chat speaks replies aloud through the device synthesiser; off makes it a hands-free listening surface only.
    static var speakReplies: Bool {
        get { defaults.object(forKey: "hermes.voice.speakReplies") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hermes.voice.speakReplies") }
    }
}

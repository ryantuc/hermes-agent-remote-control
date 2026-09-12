import Foundation
import HermesServeKit

/// Client-local Live Activity preferences (FEAT-019): device choices, not agent config, so whether this iPhone puts chats on its own Lock Screen is not something the backend can know or should store.
enum LiveActivityPreferences {
    private static let defaults = UserDefaults.standard

    /// The master toggle, off by default because a Live Activity puts a running agent's tool names on a lock screen anyone standing near the phone can read; it covers both presentations.
    static var enabled: Bool {
        get { defaults.object(forKey: "hermes.activity.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hermes.activity.enabled") }
    }

    /// Auto-start a card for a turn a cron schedule began rather than a person; on by default within the master toggle, because nobody is looking at the app during an unattended run.
    static var autoStartForCron: Bool {
        get { defaults.object(forKey: "hermes.activity.cron") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hermes.activity.cron") }
    }

    /// Fill the Lock Screen card; off does not remove the presentation — nothing can, while the activity lives — it empties it.
    static var lockScreen: Bool {
        get { defaults.object(forKey: "hermes.activity.lockScreen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hermes.activity.lockScreen") }
    }

    /// Fill the Dynamic Island; off draws nothing in any island region, but iOS may still show a plain empty pill that is not ours to remove.
    static var island: Bool {
        get { defaults.object(forKey: "hermes.activity.island") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hermes.activity.island") }
    }

    /// The two switches as one value, which is how the controller and the content state carry them.
    static var surfaces: LiveActivitySurfaces {
        get { LiveActivitySurfaces(lockScreen: lockScreen, island: island) }
        set {
            lockScreen = newValue.lockScreen
            island = newValue.island
        }
    }

    /// Which turns earn a card at all; an unrecognised stored value, written by a later build and downgraded onto, falls back to the default rather than to no cards at all.
    static var showPolicy: LiveActivityShowPolicy {
        get {
            guard let raw = defaults.string(forKey: "hermes.activity.when"),
                  let policy = LiveActivityShowPolicy(rawValue: raw)
            else { return .everyTurn }
            return policy
        }
        set { defaults.set(newValue.rawValue, forKey: "hermes.activity.when") }
    }

    /// May this app put an activity up at all: the master, and at least one surface to put something on, because ActivityKit cannot request half an activity.
    static var presentationAllowed: Bool {
        enabled && !surfaces.isEmpty
    }
}

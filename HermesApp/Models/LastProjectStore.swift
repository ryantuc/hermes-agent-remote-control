import Foundation

/// FEAT-028: how long a project pick keeps seeding new conversations, as a duration the user picks rather than a constant; both ends are reachable, so `off` is FEAT-001 disabled and `always` is FEAT-018 disabled.
enum ProjectStickiness: String, CaseIterable, Sendable {
    case off
    case tenMinutes
    case oneHour
    /// The pick never expires — pre-decay behaviour, for anyone who liked it.
    case always

    static let storageKey = "hermes.project.stickiness"

    /// What a phone that has never seen this control does, named rather than inlined so the "nothing changes on upgrade" promise is one symbol.
    static let fallback = ProjectStickiness.tenMinutes

    /// Read from the same `defaults` the store is reading, never from `.standard`: an `@AppStorage` read would reach past the store's injection and let the device decide what a unit test measures.
    static func current(defaults: UserDefaults = .standard) -> ProjectStickiness {
        guard let raw = defaults.string(forKey: storageKey), let value = ProjectStickiness(rawValue: raw) else {
            return fallback
        }
        return value
    }

    /// How long a pick lives, as three cases rather than a `TimeInterval?` in which nil would mean forever and 0 never.
    enum Horizon: Equatable {
        case never
        case within(TimeInterval)
        case forever
    }

    var horizon: Horizon {
        switch self {
        case .off: return .never
        case .tenMinutes: return .within(10 * 60)
        case .oneHour: return .within(60 * 60)
        case .always: return .forever
        }
    }

    /// The segmented control's rungs, short because there are four of them on a phone's width.
    var label: String {
        switch self {
        case .off: return "Off"
        case .tenMinutes: return "10 min"
        case .oneHour: return "1 hour"
        case .always: return "Always"
        }
    }
}

/// The project a fresh Home draft should start in, remembered per backend profile and time-boxed (FEAT-001, FEAT-018); keyed per profile, because a path remembered on one machine is meaningless on another.
enum LastProjectStore {
    static let keyPrefix = "hermes.project.last."
    /// The stamp's own prefix, deliberately not a suffix under `keyPrefix`, which would be one rename away from colliding with a profile's key.
    static let timestampPrefix = "hermes.project.lastAt."

    /// One key per profile; `none` covers the window before a profile is active, as a real key rather than a silent no-op.
    static func key(profileID: UUID?) -> String {
        keyPrefix + (profileID?.uuidString ?? "none")
    }

    static func timestampKey(profileID: UUID?) -> String {
        timestampPrefix + (profileID?.uuidString ?? "none")
    }

    /// The remembered project, or nil when this profile has never had one or the window has closed; expiry hides the value and never erases it, because this is read inside a view body where a write would fire on every redraw.
    static func remembered(profileID: UUID?, defaults: UserDefaults = .standard, now: Date = Date()) -> String? {
        let stored = defaults.string(forKey: key(profileID: profileID)) ?? ""
        guard !stored.isEmpty else { return nil }

        // Read from the injected defaults, so a unit test measures the value it stored and not the one on the simulator.
        switch ProjectStickiness.current(defaults: defaults).horizon {
        case .never:
            // The value is not erased: a read must not write, and turning the setting back on has to bring the last pick back with it.
            return nil

        case .forever:
            // Under `always` age is not being asked about, so an unstamped value has nothing to fail and this is genuinely pre-decay behaviour.
            return stored

        case .within(let window):
            let stamp = defaults.object(forKey: timestampKey(profileID: profileID)) as? Double
            guard let stamp else { return nil }
            // A stamp in the future is a clock that moved, and it would otherwise never expire, so fail closed.
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: stamp))
            guard age >= 0, age < window else { return nil }
            return stored
        }
    }

    /// Record a pick and open the window on it; a blank path is dropped rather than stored, since writing it would blank the next draft's chip on a value nobody chose.
    static func remember(_ cwd: String, profileID: UUID?, defaults: UserDefaults = .standard, now: Date = Date()) {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: key(profileID: profileID))
        defaults.set(now.timeIntervalSince1970, forKey: timestampKey(profileID: profileID))
    }

    /// Forget this profile's project; the stamp goes with it, or a path written under this profile afterwards would inherit a window it never opened.
    static func forget(profileID: UUID?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(profileID: profileID))
        defaults.removeObject(forKey: timestampKey(profileID: profileID))
    }
}

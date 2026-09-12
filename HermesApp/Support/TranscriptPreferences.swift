import Foundation
import Observation

/// The observable mirror of the transcript preferences.
@Observable
final class TranscriptPreferencesStore {
    /// The persistence side effect cannot ride a `didSet` — `@Observable` rewrites tracked stored properties into computed ones — so it lives in the facade's setters below.
    var toolCardsExpandByDefault: Bool
    var groupRepeatedCalls: Bool
    var showDiffs: Bool
    var showBranchAction: Bool
    var showCopyAction: Bool
    var showReadAloudAction: Bool
    var showRetryAction: Bool

    init(defaults: UserDefaults = .standard) {
        toolCardsExpandByDefault = defaults.bool(forKey: TranscriptPreferences.Key.toolsExpanded)
        groupRepeatedCalls = defaults.object(forKey: TranscriptPreferences.Key.groupCalls) as? Bool ?? true
        showDiffs = defaults.object(forKey: TranscriptPreferences.Key.showDiffs) as? Bool ?? true
        showBranchAction = defaults.object(forKey: TranscriptPreferences.Key.actionBranch) as? Bool ?? true
        showCopyAction = defaults.object(forKey: TranscriptPreferences.Key.actionCopy) as? Bool ?? true
        showReadAloudAction = defaults.object(forKey: TranscriptPreferences.Key.actionReadAloud) as? Bool ?? true
        showRetryAction = defaults.object(forKey: TranscriptPreferences.Key.actionRetry) as? Bool ?? true
    }
}

/// Client-local transcript preferences: display choices, not agent config, so they live in UserDefaults and never touch the wire.
enum TranscriptPreferences {
    enum Key {
        static let toolsExpanded = "hermes.transcript.toolsExpanded"
        static let groupCalls = "hermes.transcript.groupCalls"
        static let showDiffs = "hermes.transcript.showDiffs"
        static let actionBranch = "hermes.transcript.actionBranch"
        static let actionCopy = "hermes.transcript.actionCopy"
        static let actionReadAloud = "hermes.transcript.actionReadAloud"
        static let actionRetry = "hermes.transcript.actionRetry"
    }

    private static let defaults = UserDefaults.standard

    /// One instance for the process — a second would observe nothing the first wrote.
    static let store = TranscriptPreferencesStore()

    /// Tool cards land expanded instead of collapsed.
    static var toolCardsExpandByDefault: Bool {
        get { store.toolCardsExpandByDefault }
        set {
            store.toolCardsExpandByDefault = newValue
            defaults.set(newValue, forKey: Key.toolsExpanded)
        }
    }

    /// Consecutive same-tool calls collapse into one ×N row.
    static var groupRepeatedCalls: Bool {
        get { store.groupRepeatedCalls }
        set {
            store.groupRepeatedCalls = newValue
            defaults.set(newValue, forKey: Key.groupCalls)
        }
    }

    /// Edit calls render unified diffs (off falls back to the plain result).
    static var showDiffs: Bool {
        get { store.showDiffs }
        set {
            store.showDiffs = newValue
            defaults.set(newValue, forKey: Key.showDiffs)
        }
    }

    // Which of the four message actions appear.

    static var showBranchAction: Bool {
        get { store.showBranchAction }
        set {
            store.showBranchAction = newValue
            defaults.set(newValue, forKey: Key.actionBranch)
        }
    }

    static var showCopyAction: Bool {
        get { store.showCopyAction }
        set {
            store.showCopyAction = newValue
            defaults.set(newValue, forKey: Key.actionCopy)
        }
    }

    static var showReadAloudAction: Bool {
        get { store.showReadAloudAction }
        set {
            store.showReadAloudAction = newValue
            defaults.set(newValue, forKey: Key.actionReadAloud)
        }
    }

    static var showRetryAction: Bool {
        get { store.showRetryAction }
        set {
            store.showRetryAction = newValue
            defaults.set(newValue, forKey: Key.actionRetry)
        }
    }
}

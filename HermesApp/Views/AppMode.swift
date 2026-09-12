import SwiftUI

/// Which of the app's two top-level surfaces the shell is showing; mode governs Home, the hub and the far-right control, and nothing else.
enum AppMode: String, Hashable, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case bots = "Bots"

    var id: String { rawValue }

    var label: String { rawValue }
}

extension AppMode {
    /// A key of its own: `hermes.hub.mode` means Sessions-vs-Projects grouping, and a third value written there would render the Sessions history under a "Bots" selection.
    static let launchModeStorageKey = "hermes.app.launchMode"

    /// The mode the app opens in, from the stored setting; the running mode is never written back.
    static func launchMode(stored: String?) -> AppMode {
        guard let stored, let mode = AppMode(rawValue: stored) else { return .sessions }
        return mode
    }
}

/// The path arithmetic of a mode switch: one live path and one stash, so entering Bots puts the Sessions path aside and leaving Bots puts it back.
enum BotsRouteMemory {

    /// The two writes entering Bots mode makes.
    struct Transition: Equatable {
        let path: [AppRoute]
        /// What is held for the way back.
        let stashed: [AppRoute]
    }

    /// Switching into Bots mode; `remembered` is supplied only when the roster knows that profile, since a route for a bot the backend no longer has cannot resolve.
    static func enter(path: [AppRoute], remembered: BotThreadRef?) -> Transition {
        Transition(
            path: remembered.map { [.thread(.bot($0))] } ?? [],
            // A bot route restored into the Sessions stack would sit behind a Sessions Back button.
            stashed: path.filter { !$0.isBotThread }
        )
    }

    /// Switching back to Sessions mode: the stashed path, restored, and the live Bots path discarded rather than merged.
    static func leave(path: [AppRoute], stashed: [AppRoute]) -> [AppRoute] {
        stashed.filter { !$0.isBotThread }
    }
}

extension AppRoute {
    /// True for a route that displays a bot's forever-chat.
    var isBotThread: Bool {
        guard case .thread(let route) = self, case .bot = route else { return false }
        return true
    }
}

extension ThreadRoute {
    /// True for a bot's forever-chat.
    var isBot: Bool {
        guard case .bot = self else { return false }
        return true
    }
}

import Foundation

/// Where a settings jump made from inside a conversation should land (BUG-100): the requested route describes the whole stack with the conversation still underneath, since `RootView` applies a route as an absolute assignment and Back would otherwise land on Home.
enum ComposerSettingsRoute {
    static func path(from thread: ThreadRoute?, to screen: AppRoute) -> [AppRoute] {
        guard let thread else { return [.settings, screen] }
        return [.thread(thread), .settings, screen]
    }
}

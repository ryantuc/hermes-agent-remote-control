import ActivityKit
import HermesServeKit

/// The ActivityKit contract, compiled into both the app and the widget extension, so it may reference nothing app-only (`AppModel`, `Theme`, the app container's defaults).
struct HermesActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivitySnapshot

    /// The runtime session id; one card per chat, keyed by this.
    var sessionKey: String
    /// The backend this chat is talking to, shown small under the title.
    var backendName: String
    /// The skin at the moment the card was requested; attributes are immutable for the life of an activity, so a mid-turn skin change does not repaint a live card.
    var skin: LiveActivitySkinSeed
}

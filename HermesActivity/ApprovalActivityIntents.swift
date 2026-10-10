import AppIntents
import HermesServeKit

/// What the app installs so a button drawn in the widget process can be answered by the app process; `LiveActivityIntent` runs `perform()` in the app, but the intent type compiles into both targets because the widget declares the `Button(intent:)`, and the widget process never installs a handler.
@MainActor
protocol ApprovalActivityHandling: AnyObject {
    /// Everything except the second factor, so the intent can refuse a dead button without raising a Face ID sheet.
    ///
    /// BUG-070: `async` because the handler is installed before the `AppModel` exists and has to wait briefly for the model that owns the approval queue.
    func canAnswerFromActivity(token: String, session: String, approving: Bool) async -> Bool
    /// The gated path. Runs the biometric and answers only on `.submit`.
    func approveFromActivity(token: String, session: String) async
    /// The fail-closed path. No second factor, by design.
    func denyFromActivity(token: String, session: String) async
}

@MainActor
enum ApprovalActivityBridge {
    /// Installed once at app launch; nil in the widget extension's process, which is correct.
    static weak var handler: (any ApprovalActivityHandling)?
}

/// Approve the command shown in the Dynamic Island's expanded presentation.
///
/// `openAppWhenRun` is the gate: `LocalAuthentication` cannot show a Face ID sheet from a background process, so the app is foregrounded first and the biometric runs there. A failure to foreground makes `IslandApprovalGate` answer `.refuseUnauthenticated`, never a silent approval.
struct ApproveApprovalFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve command"
    static let description = IntentDescription("Approve the command Hermes is waiting on, after confirming it is you.")
    /// Bring the app forward; without a foreground there is no gate.
    static let openAppWhenRun: Bool = true
    /// Not a Shortcuts action; it exists to be a button on one card.
    static let isDiscoverable: Bool = false

    /// The client-side identity of the request this button was drawn for.
    @Parameter(title: "Request")
    var token: String

    /// The runtime session: approvals are answered positionally per session, so the token must be at the head of that session's queue.
    @Parameter(title: "Session")
    var session: String

    init() {}
    init(token: String, session: String) {
        self.token = token
        self.session = session
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = ApprovalActivityBridge.handler else { return .result() }
        // Pre-flight before authenticating: a button on a timed-out card must not raise a Face ID prompt.
        guard await handler.canAnswerFromActivity(token: token, session: session, approving: true) else {
            return .result()
        }
        await handler.approveFromActivity(token: token, session: session)
        return .result()
    }
}

/// Deny the command.
///
/// No second factor and no app launch, because denying is the fail-closed answer. It still carries the token: `approval.request` has no id on the wire and is answered positionally, so a late button would otherwise deny whatever took the head slot.
struct DenyApprovalFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny command"
    static let description = IntentDescription("Deny the command Hermes is waiting on.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    @Parameter(title: "Request")
    var token: String

    @Parameter(title: "Session")
    var session: String

    init() {}
    init(token: String, session: String) {
        self.token = token
        self.session = session
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = ApprovalActivityBridge.handler else { return .result() }
        guard await handler.canAnswerFromActivity(token: token, session: session, approving: false) else {
            return .result()
        }
        await handler.denyFromActivity(token: token, session: session)
        return .result()
    }
}

/// The URL a card opens when tapped, and the one the island offers instead of Approve when the command is too long to show whole.
enum HermesActivityLink {
    static let scheme = "hermes"

    /// Non-optional on purpose: `Link` needs a `URL`, and a key the components cannot carry lands on `home` rather than nowhere.
    static func chat(sessionKey: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "chat"
        components.path = "/" + sessionKey
        return components.url ?? home
    }

    /// `hermes://chat`, which `sessionKey(from:)` reads as no chat, so `RootView` lands on Home.
    ///
    /// No force-unwrap (BUG-146): this type runs in the widget process too, where a trap blanks every card at once. The file-URL arm is unreachable, because a scheme and a host with no path always form a URL, and `sessionKey(from:)` reads a file URL as no chat as well.
    static let home: URL = {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "chat"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    /// Parses `hermes://chat/<session id>` and returns nil for anything else.
    static func sessionKey(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "chat" else { return nil }
        let key = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return key.isEmpty ? nil : key
    }
}

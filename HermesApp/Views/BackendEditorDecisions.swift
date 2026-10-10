import Foundation
import HermesServeKit

/// The backend editor's decisions, lifted out of the view so what the screen decides is assertable without hosting it.

// MARK: - Method

/// The authentication methods the editor offers, in menu order.
///
/// Four, not five: `BackendAuthMode.auto` is a wire value the editor no longer needs, and a profile still carrying it displays as Session token.
///
/// The titles are short so the row fits on one line beside the "Method" label at every Dynamic Type size (BUG-118).
enum BackendAuthMethod: String, CaseIterable, Identifiable {
    case password
    case bearer
    case sessionToken
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Password"
        case .bearer: return "Access token"
        case .sessionToken: return "Session token"
        case .none: return "None"
        }
    }

    var authMode: BackendAuthMode {
        switch self {
        case .password: return .password
        case .bearer: return .bearer
        case .sessionToken: return .sessionToken
        case .none: return .none
        }
    }

    /// The menu row a stored mode selects; `.auto` reads as Session token.
    static func from(_ mode: BackendAuthMode) -> BackendAuthMethod {
        switch mode {
        case .password: return .password
        case .bearer: return .bearer
        case .sessionToken, .auto: return .sessionToken
        case .none: return .none
        }
    }

    /// Whether this method needs a secret before it can connect.
    var needsCredential: Bool { self != .none }

    /// What the Save button says is missing.
    var credentialNoun: String {
        switch self {
        case .password: return "password"
        case .bearer: return "access token"
        case .sessionToken: return "session token"
        case .none: return ""
        }
    }
}

// MARK: - Probe

/// What the address field's as-you-type probe of `GET /api/status` has found.
enum BackendProbeState: Equatable {
    case idle
    case probing
    case found(version: String, authRequired: Bool)
    case notFound(reason: String)

    /// The one line under the address field, deliberately one line in all four states rather than a group that appears and disappears.
    var statusLine: String? {
        switch self {
        case .idle:
            return nil
        case .probing:
            return "Looking for a backend…"
        case .found(let version, let authRequired):
            let gate = authRequired ? "sign-in required" : "no sign-in needed"
            let name = version.isEmpty ? "Hermes" : "Hermes \(version)"
            return "\(name) · \(gate)"
        case .notFound(let reason):
            return reason.isEmpty
                ? "Nothing answered at this address"
                : "Nothing answered at this address — \(reason)"
        }
    }

    var isProbing: Bool { self == .probing }

    var didFind: Bool {
        if case .found = self { return true }
        return false
    }
}

/// The short cause a failed probe reports, in the words a person would use.
///
/// Two passes, because the probe's error arrives flattened: `AuthenticationClient.perform` maps anything it does not recognise to `connectFailed(localizedDescription)`, so the code is gone by the time the editor sees it.
enum BackendProbeReason {
    static func short(for error: Error) -> String {
        if let urlError = error as? URLError, let named = named(urlError.code) {
            return named
        }
        let described = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let recognised = recognised(described) { return recognised }
        return clause(described)
    }

    private static func named(_ code: URLError.Code) -> String? {
        switch code {
        case .timedOut: return "timed out"
        case .cannotConnectToHost: return "connection refused"
        case .cannotFindHost: return "no such host"
        case .notConnectedToInternet: return "this device is offline"
        case .networkConnectionLost: return "the connection dropped"
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .secureConnectionFailed:
            return "certificate not trusted"
        case .unsupportedURL, .badURL: return "that address is not a URL"
        case .appTransportSecurityRequiresSecureConnection: return "http is not allowed here"
        default: return nil
        }
    }

    /// The sentences `NSURLErrorDomain` produces, matched on a lowercased substring because this app ships in English only.
    private static func recognised(_ described: String) -> String? {
        let text = described.lowercased()
        if text.contains("could not connect to the server") { return "connection refused" }
        if text.contains("timed out") { return "timed out" }
        if text.contains("hostname could not be found") { return "no such host" }
        if text.contains("appears to be offline") { return "this device is offline" }
        if text.contains("certificate for this server is invalid") { return "certificate not trusted" }
        if text.contains("network connection was lost") { return "the connection dropped" }
        return nil
    }

    /// A sentence turned into a clause: no capital, no full stop.
    private static func clause(_ described: String) -> String {
        var text = described.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first, first.isUppercase else { return text }
        // Only when the rest of the word is not an acronym or a host name the user typed.
        let rest = text.dropFirst()
        guard rest.prefix(3).allSatisfy({ !$0.isUppercase }) else { return text }
        return first.lowercased() + rest
    }
}

// MARK: - Credential

/// What the editor writes to the Keychain for a typed credential.
enum BackendCredentialInput {
    /// The secret to store for `method` from what was typed, or nil to keep the stored one.
    ///
    /// A token never contains whitespace: the backend mints its session token with `secrets.token_urlsafe` and compares the header byte for byte, and an access token is a JWT. So every space and line break in a token field came with the paste and is removed, and a token field holding nothing else keeps the stored token instead of overwriting it. A password is stored exactly as typed, because a password may contain spaces.
    static func secretToStore(_ typed: String, for method: BackendAuthMethod) -> String? {
        switch method {
        case .sessionToken, .bearer:
            let token = typed.filter { !$0.isWhitespace }
            return token.isEmpty ? nil : token
        case .password:
            return typed.isEmpty ? nil : typed
        case .none:
            return nil
        }
    }
}

// MARK: - Save

/// Whether Save can be tapped, and — when it cannot — the one line under it that says what is missing.
///
/// Save depends on the address and the credential, and on nothing Test does; testing first is not a precondition.
struct BackendSaveDecision: Equatable {
    let isEnabled: Bool
    /// Non-nil only when `isEnabled` is false.
    let reason: String?

    static func decide(
        addressParses: Bool,
        method: BackendAuthMethod,
        typedCredential: String,
        hasStoredCredential: Bool
    ) -> BackendSaveDecision {
        guard addressParses else {
            return BackendSaveDecision(
                isEnabled: false,
                reason: "Enter the backend's address to save."
            )
        }
        guard method.needsCredential else {
            return BackendSaveDecision(isEnabled: true, reason: nil)
        }
        let typed = typedCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        // A stored credential counts: editing a saved backend's name must not demand its password be typed again.
        guard !typed.isEmpty || hasStoredCredential else {
            return BackendSaveDecision(
                isEnabled: false,
                reason: "Enter the \(method.credentialNoun) to save."
            )
        }
        return BackendSaveDecision(isEnabled: true, reason: nil)
    }

    /// The line that sits under Save whatever its state — the answer to "do I have to test first".
    static let caption = "Save connects right away. Testing first is optional."
}

// MARK: - Copy

/// What the editor says, in words a person setting up the app for the first time can act on: no environment variables, header names or protocol frames.
enum BackendEditorCopy {
    /// An example address, drawn verbatim: a `LocalizedStringKey` title is auto-linked, so an address placeholder used to draw in link blue and read as already filled in.
    static let addressPlaceholder = "http://192.168.1.20:9119"
    static let addressHelp = "The address and port your Hermes backend listens on."
    static let sessionTokenHelp = "The session token your backend prints when it starts. It changes each time the backend restarts unless a fixed one is set."
    static let accessTokenHelp = "The access token your backend's sign-in issues. HARC sends it with every request."
    static let passwordHelp = "Leave Provider empty unless the backend offers more than one way to sign in. The password is stored in the iOS Keychain and used only to sign in again when the session expires."
    static let noneHelp = "Sends no credential. Use this only for a backend that asks for no sign-in."
    static let profileFooter = "Optional. The name of a Hermes profile on that computer. Leave empty for the default."
    static let testFooter = "Optional. Opens a real connection to check the address and the sign-in together."

    /// Every help line the editor draws, for the test that keeps developer words out of them.
    static let all = [addressHelp, sessionTokenHelp, accessTokenHelp, passwordHelp, noneHelp, profileFooter, testFooter]
}

import Foundation

/// Every failure the kit surfaces, with classification helpers that pair an error code with its method rather than string-matching the message (jsonrpc-methods-and-events.md §7).
public enum HermesError: Error, Sendable, Equatable {
    /// No open socket.
    case notConnected
    case invalidURL(String)
    /// A request's own deadline elapsed; `prompt.submit` gets 30 minutes, every other method 30 s (reference-clients.md §1.9).
    case requestTimedOut(method: String, seconds: Int)
    /// The socket closed while calls were in flight; every pending call is rejected with this.
    case connectionClosed(String)
    case connectFailed(String)
    /// The open budget elapsed with neither `gateway.ready` nor a close — the "hung, nothing came back" shape, where a socket that dies instead reports `connectionClosed`.
    case handshakeTimedOut
    case unauthorized(String)
    /// 503 from the auth gate: the IdP is unreachable, so retry rather than log out (rest-api-and-auth.md §2.11).
    case providerUnreachable(String)
    case httpStatus(code: Int, message: String)
    /// A JSON-RPC error frame; `data` carries the server's structured detail because 4090 alone cannot separate the ownership fence from unrelated refusals (BUG-141).
    case rpc(code: Int, message: String, data: JSONValue? = nil)
    case malformedResponse(String)
    case missingCredential(String)
    case attachmentTooLarge(bytes: Int, limit: Int)
    case unsupported(String)
}

extension HermesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the Hermes gateway."
        case .invalidURL(let detail):
            return "That server address isn't usable: \(detail)"
        case .requestTimedOut(let method, let seconds):
            return "Request timed out after \(seconds)s: \(method)"
        case .connectionClosed(let reason):
            return reason.isEmpty ? "The gateway connection closed." : reason
        case .connectFailed(let reason):
            return reason.isEmpty ? "Could not connect to the Hermes gateway." : reason
        case .handshakeTimedOut:
            return "The gateway never finished connecting — no gateway.ready and no close. "
                + "The server may be unreachable."
        case .unauthorized(let detail):
            return detail.isEmpty ? "Not signed in." : detail
        case .providerUnreachable(let detail):
            return "The backend's auth provider is unreachable: \(detail)"
        case .httpStatus(let code, let message):
            return message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
        case .rpc(let code, let message, _):
            return message.isEmpty ? "Hermes RPC failed (\(code))" : message
        case .malformedResponse(let detail):
            return "Unexpected response from the backend: \(detail)"
        case .missingCredential(let detail):
            return detail
        case .attachmentTooLarge(let bytes, let limit):
            let mb = Double(bytes) / 1_048_576
            let capMB = Double(limit) / 1_048_576
            return String(format: "Attachment is %.1f MB; the backend cap is %.0f MB.", mb, capMB)
        case .unsupported(let detail):
            return detail
        }
    }
}

extension HermesError {
    /// WS close codes the gateway uses for credential/host rejection (rest-api-and-auth.md §1.13).
    public static let authRejectionCloseCodes: Set<Int> = [4401, 4403]

    /// True when the right recovery is "sign in again", not "retry the socket".
    public var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized: return true
        case .httpStatus(let code, _): return code == 401
        case .connectFailed(let reason), .connectionClosed(let reason):
            return HermesError.authRejectionCloseCodes.contains { reason.contains("\($0)") }
        default: return false
        }
    }

    /// True when a reconnect + retry is the appropriate response.
    public var isTransportFailure: Bool {
        switch self {
        case .notConnected, .connectionClosed, .connectFailed, .handshakeTimedOut:
            return true
        case .requestTimedOut:
            // A `prompt.submit` timeout is also a stale runtime id (reference-clients.md §7.4).
            return true
        default:
            return false
        }
    }

    /// 4001 (live sid) and 4007 (durable id) both mean "resume and retry" (jsonrpc-methods-and-events.md §7).
    public var isSessionNotFound: Bool {
        switch self {
        case .rpc(let code, let message, _):
            if code == 4001 || code == 4007 { return true }
            return message.range(of: "session not found", options: .caseInsensitive) != nil
        default:
            return false
        }
    }

    /// 4009 `no pending <key> request` — a clarify/sudo/secret answer that arrived after the prompt expired, which is benign and swallowed (reference-clients.md §5.3).
    public var isMissingPendingPrompt: Bool {
        guard case .rpc(let code, let message, _) = self else { return false }
        return code == 4009 && message.range(of: "no pending", options: .caseInsensitive) != nil
    }

    /// 4009 on `session.resume` — the session is alive but its disconnect interrupt has not settled, so the refusal is transient and the next resume attaches.
    /// Keyed on 4009 that is not the missing-pending shape rather than on the message text, and deliberately not folded into `isSessionNotFound`, which means the session is gone (BUG-114).
    public var isResumeSettling: Bool {
        guard case .rpc(let code, _, _) = self else { return false }
        return code == 4009 && !isMissingPendingPrompt
    }

    /// 4090 — the process-wide active-session lease is exhausted.
    public var isActiveSessionLimit: Bool {
        guard case .rpc(let code, _, _) = self else { return false }
        return code == 4090
    }

    /// The three machine-readable labels 0.21.0 attaches to a refused `prompt.submit` (BUG-141).
    public enum ActiveSessionRefusal: String, Sendable {
        /// Another surface holds this conversation, and retrying cannot help until it lets go.
        case sessionNotOwned = "SESSION_NOT_OWNED"
        /// The operator's concurrency cap is full; genuinely transient.
        case maxConcurrentSessions = "MAX_CONCURRENT_SESSIONS"
        /// The backend cannot read its own ownership bookkeeping, so it cannot prove nobody else owns this and needs a fix on the computer.
        case coordinationUnavailable = "SESSION_COORDINATION_UNAVAILABLE"
    }

    /// The typed refusal behind a 4090, where `nil` is a real answer meaning "behave exactly as before": an older backend, upstream's unlabeled fourth shape, or a label this build has never heard of.
    /// Keyed on `data.reason` and never on the code alone, because 4090 is not a dedicated fence code and other backend methods return it for unrelated refusals.
    public var activeSessionRefusal: ActiveSessionRefusal? {
        guard case .rpc(let code, _, let data) = self, code == 4090,
              case .object(let fields)? = data,
              case .string(let reason)? = fields["reason"]
        else { return nil }
        return ActiveSessionRefusal(rawValue: reason)
    }

    /// Convert a transport-level codec error into the typed domain error.
    static func from(_ error: Error) -> HermesError {
        if let hermes = error as? HermesError { return hermes }
        if let rpc = error as? JSONRPCError {
            if rpc.code == -32000 { return .notConnected }
            // `data` rides through this boundary so the typed refusal label reaches the app (BUG-141).
            return .rpc(code: rpc.code, message: rpc.message, data: rpc.data)
        }
        if error is CancellationError { return .connectionClosed("Cancelled") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return .connectFailed(ns.localizedDescription)
        }
        return .connectFailed(ns.localizedDescription)
    }
}

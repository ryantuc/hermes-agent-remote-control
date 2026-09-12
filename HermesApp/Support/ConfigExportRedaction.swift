import Foundation
import HermesServeKit

/// What leaves the phone when someone taps About → Export configuration (BUG-085).
///
/// `load_config()` expands `${VAR}` before `GET /api/config` responds, so the
/// secret arrives literal; this pass is client-side and best-effort, which the
/// copy has to say. `Redaction.sensitiveQueryKeys` is deliberately not reused as
/// the name set — it is tuned for URL queries and contains `key`, `code` and
/// `state`, each an ordinary word in a configuration file.
enum ConfigExportRedaction {
    struct Result: Equatable {
        /// The document as it may leave the phone.
        var document: JSONValue
        /// How many key sites were condemned by name or by path.
        var redactedKeyCount: Int
        /// How many scalar values were actually replaced.
        var redactedValueCount: Int
        /// Whether the residual pass removed a repeat of an already-found secret.
        var usedFallbackLiteralPass: Bool

        var didRedactAnything: Bool { redactedKeyCount + redactedValueCount > 0 }
    }

    /// What a removed value is replaced with; a reader has to be able to tell
    /// this was removed from this was never set.
    static let placeholder = Redaction.mask

    /// A key whose name says its value is a credential, matched
    /// case-insensitively as a substring of the leaf key.
    static let secretKeyFragments = [
        "api_key", "apikey", "password", "secret", "token",
        "basic_auth", "credential", "private_key", "authorization", "cookie",
    ]

    /// Keys that are credentials only in company — a `client_id` outside an auth
    /// pair is an identifier worth reading.
    static let scopedSecretKeys = ["client_id"]
    static let secretScopes = ["dashboard", "oauth"]

    /// Subtrees that are credential-bearing by construction: an MCP server's
    /// `env` block holds arbitrary variable names, so the whole block goes.
    static let secretSubtreeKeys = ["env"]

    /// The shortest string the residual pass will treat as a secret; below this
    /// a repeat is likelier a shared word than a leaked key.
    static let residualMinimumLength = 12

    /// True when a key's name marks its value as a credential, given where it sits.
    static func isSecretKey(_ key: String, path: [String]) -> Bool {
        let lowered = key.lowercased()
        if secretKeyFragments.contains(where: { lowered.contains($0) }) { return true }
        guard scopedSecretKeys.contains(lowered) else { return false }
        let scope = Set(path.map { $0.lowercased() })
        return secretScopes.contains { scope.contains($0) }
    }

    /// True when a key names a whole subtree that must go.
    static func isSecretSubtree(_ key: String, value: JSONValue) -> Bool {
        guard case .object = value else { return false }
        return secretSubtreeKeys.contains(key.lowercased())
    }

    static func redactForShare(_ document: JSONValue) -> Result {
        var keyCount = 0
        var valueCount = 0
        var removed: Set<String> = []
        let walked = redacting(
            document,
            path: [],
            keyCount: &keyCount,
            valueCount: &valueCount,
            removed: &removed
        )

        // The residual pass: expansion means one secret can also appear verbatim
        // under a custom header or argument, so the literal is matched too.
        let residuals = removed.filter { $0.count >= residualMinimumLength }
        guard !residuals.isEmpty else {
            return Result(
                document: walked,
                redactedKeyCount: keyCount,
                redactedValueCount: valueCount,
                usedFallbackLiteralPass: false
            )
        }
        var residualCount = 0
        let final = maskingResiduals(walked, values: residuals, count: &residualCount)
        return Result(
            document: final,
            redactedKeyCount: keyCount,
            redactedValueCount: valueCount + residualCount,
            usedFallbackLiteralPass: residualCount > 0
        )
    }

    /// Backwards-compatible shorthand for callers that only want the bytes.
    static func redact(_ document: JSONValue) -> JSONValue {
        redactForShare(document).document
    }

    // MARK: The walk

    private static func redacting(
        _ value: JSONValue,
        path: [String],
        keyCount: inout Int,
        valueCount: inout Int,
        removed: inout Set<String>
    ) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(fields.count)
            for (key, child) in fields {
                if isSecretKey(key, path: path) || isSecretSubtree(key, value: child) {
                    keyCount += 1
                    out[key] = mask(child, valueCount: &valueCount, removed: &removed)
                } else {
                    out[key] = redacting(
                        child,
                        path: path + [key],
                        keyCount: &keyCount,
                        valueCount: &valueCount,
                        removed: &removed
                    )
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map {
                redacting($0, path: path, keyCount: &keyCount, valueCount: &valueCount, removed: &removed)
            })
        case .string, .number, .bool, .null:
            return value
        }
    }

    /// Everything inside a condemned key, with the shape kept.
    private static func mask(
        _ value: JSONValue,
        valueCount: inout Int,
        removed: inout Set<String>
    ) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(fields.count)
            for (key, child) in fields {
                out[key] = mask(child, valueCount: &valueCount, removed: &removed)
            }
            return .object(out)
        case .array(let items):
            return .array(items.map { mask($0, valueCount: &valueCount, removed: &removed) })
        case .string(let text):
            guard !text.isEmpty, text != placeholder else { return value }
            valueCount += 1
            removed.insert(text)
            return .string(placeholder)
        case .number:
            valueCount += 1
            return .string(placeholder)
        case .bool, .null:
            return value
        }
    }

    private static func maskingResiduals(
        _ value: JSONValue,
        values: Set<String>,
        count: inout Int
    ) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(fields.count)
            for (key, child) in fields {
                out[key] = maskingResiduals(child, values: values, count: &count)
            }
            return .object(out)
        case .array(let items):
            return .array(items.map { maskingResiduals($0, values: values, count: &count) })
        case .string(let text):
            guard values.contains(text) else { return value }
            count += 1
            return .string(placeholder)
        case .number, .bool, .null:
            return value
        }
    }
}

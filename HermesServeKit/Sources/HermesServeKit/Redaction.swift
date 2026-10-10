import Foundation

/// Secret-scrubbing for everywhere a string could reach a log, a diagnostics export, or the screen; the backend redacts only the approval `command`, so the URLs and headers this client constructs are scrubbed here and every log site funnels through it.
public enum Redaction {
    /// Query-parameter names whose *values* are credentials.
    public static let sensitiveQueryKeys: Set<String> = [
        "token", "ticket", "internal", "password", "secret", "code", "code_verifier",
        "access_token", "refresh_token", "api_key", "key", "state",
    ]

    /// Header names whose values are credentials.
    public static let sensitiveHeaderNames: Set<String> = [
        "authorization", "cookie", "set-cookie", "x-hermes-session-token",
    ]

    /// JSON-RPC methods whose params are secrets end to end and are never logged at all, not even redacted.
    public static let secretBearingMethods: Set<String> = [
        "sudo.respond", "secret.respond", "config.set",
    ]

    public static let mask = "<redacted>"

    /// Redact a URL's credential-bearing query values, preserving shape so a diagnostics reader can still see which parameters were present.
    public static func url(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<unparseable url>"
        }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                sensitiveQueryKeys.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: mask)
                    : item
            }
        }
        components.user = nil
        components.password = nil
        return components.string ?? "<unparseable url>"
    }

    public static func url(_ string: String) -> String {
        guard let parsed = URL(string: string) else { return mask }
        return url(parsed)
    }

    public static func headers(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers {
            out[name] = sensitiveHeaderNames.contains(name.lowercased()) ? mask : value
        }
        return out
    }

    /// Best-effort scrub of free text: bearer tokens, credential-bearing query parameters, the session token header, inline `data:` payloads, well-known token prefixes, and `key: value` assignments whose key names a credential.
    /// This is the whole secret defence on the display path, since an agent asked to run `env` would otherwise put a live provider key on the screen (BUG-072A).
    public static func text(_ input: String) -> String {
        var out = input
        for pattern in Self.patterns {
            out = pattern.regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: pattern.template
            )
        }
        return out
    }

    /// Truncate for display without splitting a grapheme cluster.
    public static func truncated(_ input: String, limit: Int) -> String {
        guard input.count > limit else { return input }
        return String(input.prefix(limit)) + "…"
    }

    private struct Pattern {
        let regex: NSRegularExpression
        let template: String
    }

    /// The query-key alternation `text(_:)` uses, derived from `sensitiveQueryKeys` so the two scrubbers cannot drift apart (BUG-072B), longest first because `NSRegularExpression` alternation is ordered.
    /// Written out rather than chained because the one-line `map`/`sorted`/`joined` form defeats Swift's type checker.
    static let sensitiveQueryKeyAlternation: String = {
        var keys: [String] = []
        for key in sensitiveQueryKeys {
            keys.append(NSRegularExpression.escapedPattern(for: key))
        }
        keys.sort { (left: String, right: String) -> Bool in
            if left.count != right.count { return left.count > right.count }
            return left < right
        }
        return keys.joined(separator: "|")
    }()

    private static let patterns: [Pattern] = {
        var specs: [(pattern: String, template: String)] = [
            ("(?i)(bearer\\s+)[A-Za-z0-9._~+/=\\-]{8,}", "$1\(mask)"),
            ("(?i)([?&](?:\(sensitiveQueryKeyAlternation))=)[^&\\s\"']+", "$1\(mask)"),
            // URL-encoded assignment (`api_key%3D…`) never contains a literal `=`.
            ("(?i)([?&](?:\(sensitiveQueryKeyAlternation))%3[Dd])[A-Za-z0-9._~+/=\\-]{8,}", "$1\(mask)"),
            ("(?i)(x-hermes-session-token:\\s*)\\S+", "$1\(mask)"),
            ("data:[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]{24,}", "data:<\(mask) bytes>"),
        ]

        // Well-known token prefixes; the body class swallows a soft-wrapped continuation after a line break so a narrow card cannot print the tail of a key it just masked (BUG-072A).
        let prefixes: [(pattern: String, template: String)] = [
            ("(?i)\\b(?:sk|rk)-[A-Za-z0-9_\\-\\r\\n]{16,}", mask),
            ("(?i)\\bgh[pousr]_[A-Za-z0-9\\r\\n]{20,}", mask),
            ("(?i)\\b(?:xox[abepors]|xapp)-[A-Za-z0-9_\\-\\r\\n]{10,}", mask),
            ("(?i)\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b", mask),
        ]
        specs += prefixes

        // Only key names that are a credential in every context: `token`, `key`, `code` and `state` are deliberately absent, because `tokens: 1500` and `state: running` are ordinary agent output.
        // Quoted values get a paired-quote pattern since a passphrase can contain spaces, and `authorization` gets its own entry because its unquoted value has an internal space after the scheme.
        // The `[A-Za-z0-9_]*` prefix is load-bearing: an env dump prints `SOME_API_KEY=…` and a leading `\b` never matches before an underscore, so the closing `\b` does the discriminating.
        // The lookbehind pins that prefix to the first character of a run (BUG-154). Unpinned, the engine retried it from every position inside a run and rescanned the run's tail each time, so a 20,000-character run took minutes. A match could only ever start where a run starts, because a start inside a run loses to the earlier start whose prefix absorbs the rest, so pinning changes the cost and not the matches.
        let credentialNames: String =
            "api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret"
            + "|password|passwd|code[_-]?verifier"
        let assignmentKeyPattern: String =
            "(?i)(\"?(?<![A-Za-z0-9_])[A-Za-z0-9_]*(?:" + credentialNames + ")\\b\"?\\s*[:=]\\s*)"
        let quotedAssignmentPattern: String =
            assignmentKeyPattern + "([\"'])[^\"']*\\2"
        let unquotedAssignmentPattern: String =
            assignmentKeyPattern + "[^\\s\",;}]+"
        let authorizationPattern: String =
            "(?i)(\"?authorization\\b\"?\\s*[:=]\\s*\"?)[^\"\\r\\n,;}]+"
        let assignments: [(pattern: String, template: String)] = [
            (authorizationPattern, "$1\(mask)"),
            (quotedAssignmentPattern, "$1$2\(mask)$2"),
            (unquotedAssignmentPattern, "$1\(mask)"),
        ]
        specs += assignments

        var built: [Pattern] = []
        for spec in specs {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { continue }
            built.append(Pattern(regex: regex, template: spec.template))
        }
        return built
    }()
}

import Foundation

/// The desktop's artifact scrape, ported with the same regexes, key hints and dedupe so the two
/// clients agree on what counts as an artifact. A scrape, not an index: cheap, idempotent, with no
/// server-side truth to reconcile against.
public enum ArtifactScrape {
    public enum Kind: String, Sendable, CaseIterable {
        case image
        case file
        case link
    }

    public struct Record: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: Kind
        public let value: String
        public let label: String
        public let sessionID: String
        public let sessionTitle: String
        public let timestamp: Double
    }

    /// The slice of a transcript row the scrape reads. `toolCalls` is the raw
    /// `tool_calls` JSON when present.
    public struct Message: Sendable {
        public let role: String
        public let text: String
        public let toolCalls: JSONValue
        public let timestamp: Double

        public init(role: String, text: String, toolCalls: JSONValue = .null, timestamp: Double = 0) {
            self.role = role
            self.text = text
            self.toolCalls = toolCalls
            self.timestamp = timestamp
        }
    }

    // The desktop's exact patterns.
    private static let markdownImage = regex(#"!\[([^\]]*)\]\(([^)\s]+)\)"#)
    private static let markdownLink = regex(#"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let bareURL = regex(#"https?://[^\s<>"')]+"#)
    private static let pathLike = regex(#"(^|[\s("'`])((?:/|~/|\.\.?/)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)"#, caseInsensitive: true)
    private static let imageExt = regex(#"\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$"#, caseInsensitive: true)
    private static let fileExt = regex(#"\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|zip|tar|gz|mp3|wav|mp4|mov)(?:\?.*)?$"#, caseInsensitive: true)
    private static let keyHint = regex(#"(path|file|url|image|artifact|output|download|result|target)"#, caseInsensitive: true)

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are compile-time constants; a failure is a programmer
        // error, and an empty regex would silently skip a whole modality.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    // MARK: The scrape

    public static func collect(
        sessionID: String,
        sessionTitle: String,
        messages: [Message]
    ) -> [Record] {
        var seen = Set<String>()
        var records: [Record] = []
        let title = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled session" : sessionTitle

        for message in messages {
            guard message.role == "assistant" || message.role == "tool" else { continue }
            collectFromMessage(message) { candidate in
                let value = normalize(candidate)
                guard !value.isEmpty, looksLikeArtifact(value) else { return }
                let key = "\(sessionID):\(value)"
                guard seen.insert(key).inserted else { return }
                records.append(Record(
                    id: key,
                    kind: kind(of: value),
                    value: value,
                    label: label(for: value),
                    sessionID: sessionID,
                    sessionTitle: title,
                    timestamp: message.timestamp
                ))
            }
        }
        return records
    }

    private static func collectFromMessage(_ message: Message, push: (String) -> Void) {
        if !message.text.isEmpty {
            collectFromText(message.text, push: push)
        }

        let isToolish = message.role == "tool" || message.toolCalls != .null
        guard isToolish else { return }

        if case .array(let calls) = message.toolCalls {
            for call in calls {
                collectStringValues(call, keyPath: "tool_call") { value, keyPath in
                    let normalized = normalize(value)
                    guard !normalized.isEmpty else { return }
                    if matches(keyHint, keyPath),
                       looksLikePathOrURL(normalized) || matches(fileExt, normalized) {
                        push(normalized)
                    }
                }
            }
        }

        // Tool results are often a JSON blob in the text body.
        if let data = message.text.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
            collectStringValues(parsed, keyPath: "tool_result") { value, keyPath in
                let normalized = normalize(value)
                guard !normalized.isEmpty else { return }
                if matches(keyHint, keyPath) || looksLikePathOrURL(normalized),
                   looksLikeArtifact(normalized) {
                    push(normalized)
                }
            }
        }
    }

    private static func collectFromText(_ text: String, push: (String) -> Void) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var imageRanges: [NSRange] = []
        markdownImage.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            imageRanges.append(match.range)
            push(ns.substring(with: match.range(at: 2)))
        }

        markdownLink.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            // A markdown image is `!` + a markdown link; skip those matches.
            let start = match.range.location
            if start > 0, ns.substring(with: NSRange(location: start - 1, length: 1)) == "!" {
                return
            }
            let value = ns.substring(with: match.range(at: 2))
            if looksLikeArtifact(normalize(value)) { push(value) }
        }

        bareURL.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            let value = ns.substring(with: match.range)
            if looksLikeArtifact(normalize(value)) { push(value) }
        }

        pathLike.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            push(ns.substring(with: match.range(at: 2)))
        }
    }

    private static func collectStringValues(
        _ value: JSONValue,
        keyPath: String,
        collector: (String, String) -> Void
    ) {
        switch value {
        case .string(let string):
            collector(string, keyPath)
        case .array(let items):
            for (index, item) in items.enumerated() {
                collectStringValues(item, keyPath: "\(keyPath).\(index)", collector: collector)
            }
        case .object(let object):
            for (key, child) in object {
                collectStringValues(child, keyPath: keyPath.isEmpty ? key : "\(keyPath).\(key)", collector: collector)
            }
        default:
            break
        }
    }

    // MARK: Classification — the desktop's rules verbatim

    static func normalize(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, "),.;".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func looksLikePathOrURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
            || value.hasPrefix("file://") || value.hasPrefix("data:image/")
            || value.hasPrefix("/") || value.hasPrefix("./")
            || value.hasPrefix("../") || value.hasPrefix("~/")
    }

    static func looksLikeArtifact(_ value: String) -> Bool {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") {
            return true
        }
        if looksLikePathOrURL(value), matches(imageExt, value) || matches(fileExt, value) {
            return true
        }
        return value.hasPrefix("/") && value.contains(".")
    }

    static func kind(of value: String) -> Kind {
        if value.hasPrefix("data:image/") || matches(imageExt, value) { return .image }
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../")
            || value.hasPrefix("~/") || value.hasPrefix("file://") {
            return .file
        }
        return .link
    }

    static func label(for value: String) -> String {
        if let url = URL(string: value), url.scheme != nil {
            let leaf = url.path.split(separator: "/").last.map(String.init)
            if let leaf, !leaf.isEmpty { return leaf }
            return url.host ?? value
        }
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? value
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

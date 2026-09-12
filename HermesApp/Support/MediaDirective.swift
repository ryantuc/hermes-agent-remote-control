import Foundation
import HermesServeKit

/// The `MEDIA:` delivery convention, read the way Desktop reads it (BUG-060).
/// The grammar is Desktop's (`apps/desktop/src/lib/chat-messages/parts.ts`, `apps/desktop/src/lib/media.ts`): a line form — the token alone on its own line, optionally indented and optionally quoted — and an inline form, the token anywhere in a sentence, in that order.
/// Deliberate divergence from Desktop: it rewrites the token into a markdown link inside the message text, and this extracts it instead, handing the caller a stripped string plus a list of refs, because the phone has real chips and a real media route to render them through.
enum MediaDirective {

    /// What a `MEDIA:` token turned out to be pointing at: Desktop's `MediaKind` plus `markdown`.
    enum Kind: String, Equatable, Sendable {
        case image
        case audio
        case video
        case markdown
        case file
    }

    /// One extracted reference.
    struct Ref: Equatable, Identifiable, Sendable {
        /// The path exactly as the agent wrote it, unquoted and never normalised — a backend path is the backend's to interpret.
        let path: String
        let kind: Kind
        let name: String

        var id: String { path }
    }

    /// Desktop's extension table, verbatim, plus its markdown set.
    private static let kindByExtension: [String: Kind] = [
        "avi": .video, "mkv": .video, "mov": .video, "mp4": .video, "webm": .video,
        "flac": .audio, "m4a": .audio, "mp3": .audio, "ogg": .audio, "opus": .audio, "wav": .audio,
        "bmp": .image, "gif": .image, "jpeg": .image, "jpg": .image, "png": .image, "svg": .image, "webp": .image,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
    ]

    static func kind(of path: String) -> Kind {
        // Desktop splits on `?` and `#` first, so a query string is not part of the extension.
        let withoutQuery = path.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? path
        let name = Self.name(of: withoutQuery)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .file }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return kindByExtension[ext] ?? .file
    }

    /// The last path component, through `HostPath` rather than `NSString.lastPathComponent`, which knows one separator and so returns the whole of a Windows path.
    static func name(of path: String) -> String {
        let trimmed = path.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? path
        return HostPath.lastComponent(of: trimmed)
    }

    /// Whether this ref names a file the gateway can serve back to us. Desktop's `isFileMediaPath`, transcribed: POSIX absolute, `~/`, a drive letter, or a UNC share; `http(s)` and `data:` are not "files" in this sense.
    static func isResolvableFilePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("\\\\") { return true }
        if path.lowercased().hasPrefix("file:") { return true }
        // `C:\` or `c:/`
        let chars = Array(path)
        if chars.count >= 3, chars[0].isLetter, chars[1] == ":", chars[2] == "\\" || chars[2] == "/" { return true }
        return false
    }

    /// Not the gateway's to serve: the bytes are either already in the string (`data:`) or reachable from the phone directly (`http(s)`). Use ``fetchPlan(for:)`` when the question is where the bytes come from — SwiftUI has no `<img src>` to perform Desktop's implicit fetch, and that is the distinction this one does not draw (BUG-133).
    static func isInlineSource(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("data:")
    }

    // MARK: Where the bytes come from

    /// The three ways a ref's bytes can be obtained, decided once so no loader has to re-derive it (BUG-133).
    enum FetchPlan: Equatable, Sendable {
        case decodeDataURL
        /// A public URL the phone fetches itself, with no gateway and no credentials: the app's bearer token has no business travelling to an arbitrary host.
        case fetchRemote(URL)
        case askGateway
    }

    /// Decide how to obtain `path`; an `http(s)` string that will not parse as a `URL` falls to ``FetchPlan/askGateway`` rather than being reported as remote.
    static func fetchPlan(for path: String) -> FetchPlan {
        let lower = path.lowercased()
        if lower.hasPrefix("data:") { return .decodeDataURL }
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            if let url = URL(string: path), url.host()?.isEmpty == false { return .fetchRemote(url) }
            return .askGateway
        }
        return .askGateway
    }

    // MARK: Extraction

    /// The line form: the token alone on its own line, matched first so the line is removed with its newline rather than leaving a blank gap.
    private static let lineExpression = try? NSRegularExpression(
        pattern: #"(^|\n)[\t ]*[`"']?MEDIA:[ \t]*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)[`"']?[\t ]*(?=\n|$)"#
    )

    /// The inline form: the token anywhere in a sentence.
    private static let inlineExpression = try? NSRegularExpression(
        pattern: #"[`"']?MEDIA:[ \t]*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)[`"']?"#
    )

    /// The line form with the end-of-text alternative removed, for a message that is still arriving: `(?=\n)` instead of `(?=\n|$)`, because a token at the end of the buffer might still be half a path.
    private static let completedLineExpression = try? NSRegularExpression(
        pattern: #"(^|\n)[\t ]*[`"']?MEDIA:[ \t]*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)[`"']?[\t ]*(?=\n)"#
    )

    /// Pull every `MEDIA:` reference out of a message, and return the message without them. Order matters and is Desktop's: line form first, then inline, or inline consumes the path of a line-form token.
    /// Callers must not run this on a streaming message — use ``extractCompleted(from:)`` there, since a partial tail satisfies the `$` anchor and would extract a truncated path.
    static func extract(from text: String) -> (text: String, refs: [Ref]) {
        guard text.contains("MEDIA:") else { return (text, []) }
        return run([(lineExpression, true), (inlineExpression, false)], on: text)
    }

    /// The same extraction, restricted to tokens that are provably finished, for a message that is still streaming (BUG-133). Only the line form runs here, and only where a real newline follows it: there is no way to know a bare inline path has finished arriving when more characters can still follow it on the same line.
    static func extractCompleted(from text: String) -> (text: String, refs: [Ref]) {
        guard text.contains("MEDIA:") else { return (text, []) }
        return run([(completedLineExpression, true)], on: text)
    }

    /// One pass per expression, in the order given. `isLineForm` selects the capture group and preserves the leading newline, which is the only thing the two shapes disagree about.
    private static func run(
        _ expressions: [(NSRegularExpression?, Bool)],
        on text: String
    ) -> (text: String, refs: [Ref]) {
        var remaining = text
        var refs: [Ref] = []

        for (expression, isLineForm) in expressions.compactMap({ pair -> (NSRegularExpression, Bool)? in
            guard let expression = pair.0 else { return nil }
            return (expression, pair.1)
        }) {
            var output = ""
            var cursor = remaining.startIndex
            let full = NSRange(remaining.startIndex..<remaining.endIndex, in: remaining)

            for match in expression.matches(in: remaining, range: full) {
                guard let matchRange = Range(match.range, in: remaining) else { continue }
                // The line form keeps its leading newline: the token goes, not the paragraph break.
                let captureIndex = isLineForm ? 2 : 1
                guard match.numberOfRanges > captureIndex,
                      let captured = Range(match.range(at: captureIndex), in: remaining)
                else { continue }

                output += remaining[cursor..<matchRange.lowerBound]
                if isLineForm, match.numberOfRanges > 1,
                   let lead = Range(match.range(at: 1), in: remaining) {
                    output += remaining[lead]
                }
                if let ref = makeRef(String(remaining[captured])) {
                    refs.append(ref)
                }
                cursor = matchRange.upperBound
            }
            output += remaining[cursor...]
            remaining = output
        }

        return (tidy(remaining), dedupe(refs))
    }

    private static func makeRef(_ raw: String) -> Ref? {
        let path = unquote(raw)
        guard !path.isEmpty else { return nil }
        return Ref(path: path, kind: kind(of: path), name: name(of: path))
    }

    /// Desktop's `unquoteMediaPath`: a matched pair of `` ` ``, `"` or `'` comes off, anything else is left alone.
    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, let last = trimmed.last, trimmed.count >= 2,
              first == last, first == "`" || first == "\"" || first == "'"
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func tidy(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One chip per file: an artefact named twice is one file, not two.
    private static func dedupe(_ refs: [Ref]) -> [Ref] {
        var seen = Set<String>()
        return refs.filter { seen.insert($0.path).inserted }
    }
}

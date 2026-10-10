import Foundation
import HermesServeKit

/// Display-side scrubbing on top of `HermesServeKit.Redaction`: the kit's redaction protects logs and exports, these helpers protect the screen.
enum DisplayRedaction {
    /// Server identity for a settings row or a chat header: keeps enough to recognise the machine, drops credentials in the URL.
    static func serverIdentity(_ configuration: BackendConfiguration) -> String {
        let scheme = configuration.isSecure ? "https" : "http"
        let path = configuration.basePath
        return "\(scheme)://\(configuration.displayHost)\(path)"
    }

    /// Cap tool output and scrub obvious credential shapes before it reaches a bubble.
    /// BUG-123: the cut comes first, at `limit + margin`, so the scrubbers never walk a megabyte and still see every character that can reach the screen plus a pattern's worth of run-up past the cut.
    static func toolOutput(_ text: String, limit: Int = 4000, margin: Int = 1024) -> String {
        // `prefix` rather than a `count` comparison: counting a megabyte of grapheme clusters to decide whether to cut it is the cost this avoids.
        let head = String(text.prefix(limit + margin))
        return Redaction.truncated(Redaction.text(head), limit: limit)
    }

    /// The approval command is already redacted server-side; this is belt-and-braces for an older backend or an MCP elicitation path that skipped it.
    static func approvalCommand(_ command: String) -> String {
        Redaction.text(command)
    }

    /// A one-line preview safe to show in a list row.
    static func preview(_ text: String, limit: Int = 120) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Redaction.truncated(Redaction.text(collapsed), limit: limit)
    }

    /// Per reference-clients.md §6.4: strip the `@image:` directive lines the backend appends to a persisted user turn so they do not render as literal text.
    static func stripImageDirectives(_ text: String) -> (body: String, refs: [String]) {
        UserInputDisplay.project(text)
    }
}

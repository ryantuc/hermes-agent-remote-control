import Foundation

/// Match only the current user occurrence, never equal text anywhere in history.
public struct ResumeHistoryOverlap {
    public let userPersisted: Bool
    public let correctionCount: Int
    public let assistantPrefix: String

    public init(history: [ChatEntry], inflight: InflightSnapshot) {
        let display = UserInputDisplay.project(inflight.user)
        let normalized = display.body
        guard let start = history.lastIndex(where: { $0.kind == .user && $0.noticeKind != "correction" }),
              history[start].text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized,
              (!normalized.isEmpty || (!display.refs.isEmpty && history[start].imageRefs == display.refs)),
              inflight.startedAt.map({ history[start].timestamp >= $0.addingTimeInterval(-0.001) }) ?? true
        else {
            userPersisted = false; correctionCount = 0; assistantPrefix = ""
            return
        }
        userPersisted = true
        let tail = history[(start + 1)...]
        var corrections = 0
        var prefix = ""
        var prefixMatches = true
        for entry in tail {
            if entry.kind == .user, entry.noticeKind == "correction",
               corrections < inflight.corrections.count,
               entry.text == inflight.corrections[corrections] {
                corrections += 1
            }
            if entry.kind == .assistant, !entry.text.isEmpty, prefixMatches {
                let next = prefix + entry.text
                if inflight.assistant.hasPrefix(next) { prefix = next }
                else { prefixMatches = false }
            }
        }
        correctionCount = corrections
        assistantPrefix = prefix
    }
}

public enum SteerDisplay {
    /// Only strip the server's exact marker on a row explicitly tagged as a steer.
    public static func text(_ text: String, kind: String) -> String {
        guard kind == "steer", text.hasPrefix("[OUT-OF-BAND USER MESSAGE"),
              let boundary = text.range(of: "]\n"),
              let close = text.range(of: "[/OUT-OF-BAND USER MESSAGE]", options: .backwards),
              close.lowerBound >= boundary.upperBound,
              text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return String(text[boundary.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The same projection for persisted rows, live observations and resume input.
public enum UserInputDisplay {
    public static func project(_ text: String) -> (body: String, refs: [String]) {
        var refs: [String] = []
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@image:") { refs.append(unquote(String(trimmed.dropFirst(7)))) }
            else if trimmed == "[screenshot]" { refs.append("[screenshot]") }
            else { lines.append(line) }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }

    /// The backend wraps a reference value holding whitespace or brackets in the first of `` ` ``, `"`, `'` it does not contain (`format_reference_value` in `agent/context_references.py`), so a Windows home with a space in the account name arrives quoted.
    public static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, value.last == first, "`\"'".contains(first) else { return value }
        return String(value.dropFirst().dropLast())
    }
}
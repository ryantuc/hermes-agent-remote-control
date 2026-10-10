import Foundation
#if DEBUG
import os
#endif

/// A bounded, sanitized, in-memory log of connection lifecycle events.
///
/// This is what DiagnosticsView shows and what a user would paste into a bug
/// report, so **every** message is pushed through `Redaction.text` on the way
/// in — there is no unsanitized path and no file on disk.
public actor ConnectionLog {
    public enum Level: String, Sendable, CaseIterable {
        case debug, info, warning, error
    }

    public struct Entry: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
        /// The backend this entry was recorded under, as `enterBackend` labelled it; nil before any backend was entered.
        public let backend: String?

        public init(
            id: UUID = UUID(),
            date: Date = Date(),
            level: Level,
            category: String,
            message: String,
            backend: String? = nil
        ) {
            self.id = id
            self.date = date
            self.level = level
            self.category = category
            self.message = message
            self.backend = backend
        }
    }

    private var buffer: [Entry] = []
    private let capacity: Int
    /// Identity of the backend later entries belong to; compared, never logged.
    private var backendKey: String?
    /// What a reader sees for that backend, already redacted.
    private var backendLabel: String?

    public init(capacity: Int = 400) {
        self.capacity = max(32, capacity)
    }

    /// Attribute every later entry to one backend, and mark the trail when it is not the backend before it, so a reader can see where one machine's entries end and the next one's begin (BUG-143).
    ///
    /// `key` is the backend's identity and is only compared; `label` is what Diagnostics shows, redacted like any message.
    public func enterBackend(key: String, label: String) {
        let label = Redaction.truncated(Redaction.text(label), limit: 120)
        let changed = key != backendKey
        backendKey = key
        backendLabel = label
        if changed { record(.info, "backend", "— now on \(label) —") }
    }

    public func record(_ level: Level, _ category: String, _ message: String) {
        let entry = Entry(
            level: level,
            category: category,
            message: Redaction.truncated(Redaction.text(message), limit: 600),
            backend: backendLabel
        )
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        #if DEBUG
        // Mirror the already-redacted entry to os_log so the connection trail is
        // visible via `log stream`/Console during development. Debug builds only;
        // never compiled into a release, where the in-app Diagnostics view is the
        // only surface.
        ConnectionLog.osLogger.log("[\(entry.category, privacy: .public)] \(entry.message, privacy: .public)")
        #endif
    }

    #if DEBUG
    private static let osLogger = os.Logger(subsystem: "com.hermes.mobile.diagnostics", category: "connection")
    #endif

    public func debug(_ category: String, _ message: String) { record(.debug, category, message) }
    public func info(_ category: String, _ message: String) { record(.info, category, message) }
    public func warning(_ category: String, _ message: String) { record(.warning, category, message) }
    public func error(_ category: String, _ message: String) { record(.error, category, message) }

    public func entries() -> [Entry] { buffer }

    public func clear() { buffer.removeAll() }

    /// Plain-text export for the share sheet. Already sanitized by construction; an entry recorded under a backend carries its label in parentheses, so a pasted log names the machine on every line.
    public func export() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return buffer
            .map { entry in
                let backend = entry.backend.map { "(\($0)) " } ?? ""
                return "\(formatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(backend)\(entry.category): \(entry.message)"
            }
            .joined(separator: "\n")
    }
}

import Foundation

/// One prompt in a session's timeline (`GET /api/sessions/{id}/timeline`): where it is, what it said, when.
public struct PromptTimelineEntry: Sendable, Equatable, Identifiable {
    /// The durable row of the prompt's current representative, the address `GET …/messages/around?row_id=` takes.
    public let rowID: Int
    /// The prompt's first 120 characters with its whitespace closed up, as the backend cut it.
    public let preview: String
    /// Unix seconds.
    public let timestamp: Double

    public var id: Int { rowID }

    public init(rowID: Int, preview: String, timestamp: Double) {
        self.rowID = rowID
        self.preview = preview
        self.timestamp = timestamp
    }

    public init(json: JSONValue) {
        rowID = json["row_id"]?.coercedInt ?? 0
        preview = json["preview"]?.coercedString ?? ""
        timestamp = json["timestamp"]?.coercedDouble ?? 0
    }

    public var date: Date { Date(timeIntervalSince1970: timestamp) }
}

/// One page of a session's prompt timeline, oldest first.
public struct PromptTimelinePage: Sendable, Equatable {
    /// The session the entries belong to; the handler follows the compression chain, so it may not be the id asked for.
    public let sessionID: String
    public let entries: [PromptTimelineEntry]
    /// Every prompt in the session, not only this page's.
    public let total: Int
    /// The `after_row_id` that fetches the next page; nil on the last one.
    public let nextCursor: Int?

    public init(sessionID: String, entries: [PromptTimelineEntry], total: Int, nextCursor: Int?) {
        self.sessionID = sessionID
        self.entries = entries
        self.total = total
        self.nextCursor = nextCursor
    }

    public init(json: JSONValue, requestedSessionID: String) {
        sessionID = json["session_id"]?.coercedString ?? requestedSessionID
        entries = (json["entries"]?.arrayValue ?? []).map(PromptTimelineEntry.init(json:))
        let pagination = json["pagination"]
        total = pagination?["total"]?.coercedInt ?? entries.count
        let more = pagination?["has_more"]?.coercedBool ?? false
        nextCursor = more ? pagination?["next_cursor"]?.coercedInt : nil
    }

    public var hasMore: Bool { nextCursor != nil }
}

/// What `GET …/messages/around` says about the page it returned, beyond the rows themselves.
public struct TranscriptWindow: Sendable, Equatable {
    /// The prompt the page starts at.
    public let rowID: Int
    /// Rows before the page in the session's display history.
    public let offset: Int
    public let total: Int
    public let hasOlder: Bool
    public let hasNewer: Bool

    public init(rowID: Int, offset: Int, total: Int, hasOlder: Bool, hasNewer: Bool) {
        self.rowID = rowID
        self.offset = offset
        self.total = total
        self.hasOlder = hasOlder
        self.hasNewer = hasNewer
    }

    public init(json: JSONValue, rowID: Int) {
        let pagination = json["pagination"]
        self.rowID = pagination?["row_id"]?.coercedInt ?? rowID
        offset = pagination?["offset"]?.coercedInt ?? 0
        total = pagination?["total"]?.coercedInt ?? 0
        hasOlder = pagination?["has_older"]?.coercedBool ?? (offset > 0)
        hasNewer = pagination?["has_newer"]?.coercedBool ?? false
    }
}

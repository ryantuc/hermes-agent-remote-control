import Foundation

public struct SessionEventReplay: Sendable {
    public let epoch: String
    public let truncated: Bool
    /// Optional on older backends; a lower counter proves that this session's replay ring reset.
    public let latestSequence: Int?
    public let events: [GatewayEvent]

    public init?(json: JSONValue) {
        guard let epoch = json["epoch"]?.coercedString, !epoch.isEmpty,
              let truncated = json["truncated"]?.coercedBool,
              let rows = json["events"]?.arrayValue else { return nil }
        self.epoch = epoch
        self.truncated = truncated
        self.latestSequence = json["latest_seq"]?.coercedInt
        self.events = rows.map { row in
            GatewayEvent(type: row["type"]?.coercedString ?? "",
                         sessionID: row["session_id"]?.coercedString ?? "",
                         payload: row["payload"] ?? .null, params: row)
        }
    }
}

/// Holds events across warm reattachment so replay cannot land behind newer deltas.
/// Scoped to one server epoch. No persistence or retransmission of user requests.
final class SessionEventRecovery {
    var epoch = ""
    var watermarks: [String: Int] = [:]
    private var held: [String: [GatewayEvent]] = [:]
    private var heldBytes: [String: Int] = [:]
    private var overflow: Set<String> = []

    func setEpoch(_ next: String) {
        if next != epoch { watermarks.removeAll(); held.removeAll(); heldBytes.removeAll(); overflow.removeAll() }
        epoch = next
    }

    func begin(_ sid: String) -> Int? {
        guard !epoch.isEmpty, let seq = watermarks[sid], held[sid] == nil else { return nil }
        held[sid] = []; heldBytes[sid] = 0
        return seq
    }

    func hold(_ event: GatewayEvent) -> Bool {
        let sid = event.sessionID
        guard held[sid] != nil else { return false }
        let bytes = (try? JSONRPCCodec.encodeLine(event.params).utf8.count) ?? 0
        if held[sid]!.count >= 4096 || (heldBytes[sid] ?? 0) + bytes > 4 * 1024 * 1024 {
            overflow.insert(sid)
        } else {
            held[sid]!.append(event)
            heldBytes[sid, default: 0] += bytes
        }
        return true
    }

    func accepts(_ event: GatewayEvent) -> Bool {
        guard !epoch.isEmpty, let seq = event.params["seq"]?.coercedInt, seq > 0 else { return true }
        if seq <= watermarks[event.sessionID, default: 0] { return false }
        watermarks[event.sessionID] = seq
        return true
    }

    func finish(_ sid: String, replay: SessionEventReplay?) -> (events: [GatewayEvent], complete: Bool) {
        let buffered = held.removeValue(forKey: sid) ?? []
        heldBytes[sid] = nil
        let overflowed = overflow.remove(sid) != nil
        guard let replay, replay.epoch == epoch else { return (buffered, false) }
        if let latest = replay.latestSequence, let requested = watermarks[sid], latest < requested {
            // The backend can evict a session's ring and counter without changing its process epoch.
            // Drop the obsolete cursor before draining held frames, or fresh low-sequence events
            // would also be discarded. The caller falls back instead of restoring saved display.
            watermarks[sid] = nil
            return (buffered, false)
        }
        guard !replay.truncated, !overflowed else { return (buffered, false) }
        let events = replay.events + buffered
        guard events.allSatisfy({ $0.sessionID == sid && !$0.type.isEmpty && ($0.params["seq"]?.coercedInt ?? 0) > 0 }) else { return (buffered, false) }
        return (events.sorted { ($0.params["seq"]?.coercedInt ?? 0) < ($1.params["seq"]?.coercedInt ?? 0) }, true)
    }

    func forget(_ sid: String) {
        watermarks[sid] = nil; held[sid] = nil; heldBytes[sid] = nil; overflow.remove(sid)
    }
}

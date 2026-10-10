import Foundation
import XCTest
@testable import HermesServeKit

final class TurnCheckpointTests: XCTestCase {
    func testCheckpointRetainsOwnInputReferenceWithoutRetransmittingIt() throws {
        let before = TurnEngine()
        before.setReplayEpoch("e")
        before.apply(frame("message.start", 1, .object([:])))
        let entry = before.appendUserEntry(sessionID: "s", text: "Correction", joiningRunningTurn: true)
        before.registerSubmission(sessionID: "s", ref: "mine", entryID: entry)
        let checkpoint = try XCTUnwrap(before.checkpoint(sessionID: "s"))
        let after = TurnEngine()
        after.setReplayEpoch("e")
        XCTAssertTrue(after.beginCheckpointRecovery(checkpoint))
        let observed = frame("message.input", 2, .object([
            "input": .object(["role": .string("user"), "text": .string("Correction")]),
            "inputs": .array([.object(["id": .string("input"), "ref": .string("mine")])])]))
        XCTAssertTrue(after.finishEventRecovery(sessionID: "s", replay: replay([observed]), checkpoint: checkpoint))
        XCTAssertEqual(after.state(for: "s").entries.filter { $0.kind == .user }.map(\.id), [entry])
    }
    private func frame(_ type: String, _ seq: Int, _ payload: JSONValue) -> GatewayEvent {
        let params: JSONValue = .object(["type": .string(type), "session_id": .string("s"),
            "seq": .number(Double(seq)), "payload": payload])
        return GatewayEvent(type: type, sessionID: "s", payload: payload, params: params)
    }
    private func replay(_ events: [GatewayEvent], truncated: Bool = false) -> SessionEventReplay {
        SessionEventReplay(json: .object(["epoch": .string("e"), "truncated": .bool(truncated),
            "events": .array(events.map(\.params))]))!
    }
    func testDiskRoundTripAndNewEnginePreserveTimelineAcrossOverlappingReplay() throws {
        let before = TurnEngine()
        before.setReplayEpoch("e")
        before.apply(frame("message.start", 1, .object([:])))
        before.apply(frame("reasoning.delta", 2, .object(["text": .string("First thought")])))
        before.apply(frame("message.delta", 3, .object(["text": .string("First update")])))
        before.apply(frame("tool.start", 4, .object(["tool_id": .string("t"), "name": .string("search")])))
        before.apply(frame("reasoning.delta", 5, .object(["text": .string("After the tool")])))
        // Checkpoint itself flushes the final reasoning buffer before saving its cursor.
        let checkpoint = try XCTUnwrap(before.checkpoint(sessionID: "s"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
        let disk = try JSONDecoder().decode(TurnCheckpoint.self, from: Data(contentsOf: url))
        let after = TurnEngine()
        after.setReplayEpoch("e")
        XCTAssertTrue(after.beginCheckpointRecovery(disk))
        let next = frame("message.delta", 6, .object(["text": .string("Second update")]))
        after.apply(next) // Arrives live before the replay RPC returns the same frame.
        XCTAssertTrue(after.state(for: "s").entries.isEmpty)
        XCTAssertTrue(after.finishEventRecovery(sessionID: "s", replay: replay([next]), checkpoint: disk))
        let entries = after.state(for: "s").entries
        XCTAssertEqual(entries.map(\.kind), [.assistant, .tool, .assistant])
        XCTAssertEqual(entries.map(\.reasoning), ["First thought", "", "After the tool"])
        XCTAssertEqual(entries.map(\.text), ["First update", "", "Second update"])
        XCTAssertEqual(entries.filter { $0.tool != nil }.count, 1)
        after.apply(next)
        after.flush()
        XCTAssertEqual(after.state(for: "s").entries, entries)
    }
    func testChangedEpochAndTruncatedReplayNeverImportSavedDisplay() throws {
        let before = TurnEngine()
        before.setReplayEpoch("e")
        before.apply(frame("message.start", 1, .object([:])))
        before.apply(frame("message.delta", 2, .object(["text": .string("Saved")])))
        let checkpoint = try XCTUnwrap(before.checkpoint(sessionID: "s"))
        let restarted = TurnEngine()
        restarted.setReplayEpoch("new")
        XCTAssertFalse(restarted.beginCheckpointRecovery(checkpoint))
        restarted.setReplayEpoch("e")
        XCTAssertTrue(restarted.beginCheckpointRecovery(checkpoint))
        let fresh = frame("message.delta", 10, .object(["text": .string("Fresh")]))
        restarted.apply(fresh)
        XCTAssertFalse(restarted.finishEventRecovery(sessionID: "s", replay: replay([], truncated: true), checkpoint: checkpoint))
        XCTAssertEqual(restarted.state(for: "s").entries.last?.text, "Fresh")
        XCTAssertNil(restarted.beginEventRecovery(sessionID: "s"))
    }
}

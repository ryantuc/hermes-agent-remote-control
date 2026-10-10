import XCTest
@testable import HermesServeKit

final class ReplaySequenceRegressionTests: XCTestCase {
    private func event(_ type: String, _ seq: Int, text: String = "") -> GatewayEvent {
        let payload: JSONValue = .object(["text": .string(text)])
        let params: JSONValue = .object(["session_id": .string("s"), "type": .string(type), "seq": .number(Double(seq)), "payload": payload])
        return GatewayEvent(type: type, sessionID: "s", payload: payload, params: params)
    }

    private func replay(_ events: [GatewayEvent] = [], latest: Int? = nil, truncated: Bool = false) throws -> SessionEventReplay {
        var json: [String: JSONValue] = ["epoch": .string("e"), "truncated": .bool(truncated), "events": .array(events.map(\.params))]
        if let latest { json["latest_seq"] = .number(Double(latest)) }
        return try XCTUnwrap(SessionEventReplay(json: .object(json)))
    }

    private func checkpoint() throws -> TurnCheckpoint {
        let previous = TurnEngine()
        previous.setReplayEpoch("e")
        previous.apply(event("message.start", 1))
        previous.apply(event("message.delta", 2, text: "Saved"))
        return try XCTUnwrap(previous.checkpoint(sessionID: "s"))
    }

    func testColdCheckpointRejectsEvictedRingWithoutEpochChange() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        XCTAssertFalse(engine.finishEventRecovery(sessionID: "s", replay: try replay(latest: 0), checkpoint: saved))
        XCTAssertTrue(engine.state(for: "s").entries.isEmpty)
        XCTAssertFalse(engine.state(for: "s").isBusy)
        XCTAssertNil(engine.beginEventRecovery(sessionID: "s"))
    }

    func testRegressedReplayDrainsFreshLowSequenceFramesWithoutImportingSavedDisplay() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        engine.apply(event("message.delta", 1, text: "Fresh"))
        XCTAssertFalse(engine.finishEventRecovery(sessionID: "s", replay: try replay(latest: 1), checkpoint: saved))
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["Fresh"])
        XCTAssertNil(engine.beginEventRecovery(sessionID: "s"))
    }

    func testWarmRecoveryRejectsRegressedCounter() throws {
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        engine.apply(event("message.start", 1))
        engine.apply(event("message.delta", 2, text: "Existing"))
        XCTAssertEqual(engine.beginEventRecovery(sessionID: "s"), 2)
        XCTAssertFalse(engine.finishEventRecovery(sessionID: "s", replay: try replay(latest: 0)))
        XCTAssertNil(engine.beginEventRecovery(sessionID: "s"))
    }

    func testRegressedAndTruncatedReplayStillDrainsFreshLowSequenceFrames() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        engine.apply(event("message.delta", 1, text: "Fresh"))
        XCTAssertFalse(engine.finishEventRecovery(sessionID: "s", replay: try replay(latest: 1, truncated: true), checkpoint: saved))
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["Fresh"])
    }

    func testLatestCounterCanAdvanceAfterServerCapturesReplayRows() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        // The server reads the rows and latest counter under separate locks.
        // A later live event may therefore be absent from this response's rows.
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: try replay(latest: 3), checkpoint: saved))
        engine.apply(event("message.delta", 3, text: "After"))
        engine.flush()
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["SavedAfter"])
    }

    func testOlderReplayWithoutLatestCounterRemainsCompatible() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("e")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        let legacy = try replay([event("message.delta", 3, text: "After")])
        XCTAssertNil(legacy.latestSequence)
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: legacy, checkpoint: saved))
        XCTAssertEqual(engine.state(for: "s").entries.map(\.text), ["SavedAfter"])
    }
}

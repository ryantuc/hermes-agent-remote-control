import XCTest
@testable import HermesServeKit

final class ServerRequestRecoveryTests: XCTestCase {
    private func event(_ type: String, sequence: Int) -> GatewayEvent {
        let payload: JSONValue = .object(["text": .string("")])
        return GatewayEvent(type: type, sessionID: "s", payload: payload, params: .object([
            "type": .string(type), "session_id": .string("s"),
            "seq": .number(Double(sequence)), "payload": payload]))
    }
    private func replay(_ events: [GatewayEvent] = []) -> SessionEventReplay {
        SessionEventReplay(json: .object(["epoch": .string("epoch"), "truncated": .bool(false),
            "latest_seq": .number(Double(events.last?.params["seq"]?.intValue ?? 100)),
            "events": .array(events.map(\.params))]))!
    }
    private func checkpoint() throws -> TurnCheckpoint {
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        engine.apply(event("message.start", sequence: 100))
        return try XCTUnwrap(engine.checkpoint(sessionID: "s"))
    }
    private func registry(id: JSONValue = .number(7), method: String = "approval") -> ServerRequestRegistry {
        var registry = ServerRequestRegistry()
        registry.receive(id: id, method: method, params: .object([
            "session_id": .string("s"), "command": .string("echo synthetic"),
            "question": .string("Synthetic question")]), generation: 3)
        return registry
    }
    private func publish(_ registry: ServerRequestRegistry, to engine: TurnEngine) {
        engine.apply(GatewayEvent(type: "client.server_requests", sessionID: "s", payload: .null,
            params: .null, serverRequests: registry.open(in: "s")))
    }

    func testCheckpointRestoreKeepsExactCurrentApprovalFromLatestRegistryProjection() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        let registry = registry()
        let current = try XCTUnwrap(registry.open(in: "s").first)
        publish(registry, to: engine)
        let resume = SessionAPI.decodeResume(.object(["session_id": .string("s"),
            "running": .bool(true)]), requested: "stored", includeLegacyPrompts: false)
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: replay(),
            checkpoint: saved, resumeSnapshot: resume))
        XCTAssertEqual(engine.state(for: "s").pendingApprovals.count, 1)
        XCTAssertEqual(engine.state(for: "s").currentApproval?.serverRequest, current.identity)
        XCTAssertEqual(engine.state(for: "s").currentApproval?.id, current.id)
        XCTAssertTrue(engine.state(for: "s").needsInput)
    }

    func testWarmReplayOldCompletionCannotEraseANewTurnsCurrentRequest() throws {
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        engine.apply(event("message.start", sequence: 100))
        XCTAssertEqual(engine.beginEventRecovery(sessionID: "s"), 100)
        let registry = registry(id: .string("new-turn"), method: "secret")
        let current = try XCTUnwrap(registry.open(in: "s").first)
        publish(registry, to: engine)
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: replay([
            event("message.complete", sequence: 101), event("message.start", sequence: 102)])))
        XCTAssertEqual(engine.state(for: "s").secret?.serverRequest, current.identity)
        XCTAssertEqual(engine.state(for: "s").secret?.id, current.id.uuidString)
        XCTAssertTrue(engine.state(for: "s").needsInput)
    }

    func testLatestCancellationBeforeRecoveryFinishesCannotResurrectAPrompt() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        var registry = registry()
        publish(registry, to: engine)
        registry.cancel(id: .number(7), method: "approval", sessionID: "s", generation: 3)
        publish(registry, to: engine)
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: replay(), checkpoint: saved))
        XCTAssertFalse(engine.state(for: "s").hasBlockingPrompt)
        XCTAssertFalse(engine.state(for: "s").needsInput)
    }

    func testLatestReplacementAndAcceptedBatchLockSurviveCheckpointReplay() throws {
        let saved = try checkpoint()
        let engine = TurnEngine()
        engine.setReplayEpoch("epoch")
        XCTAssertTrue(engine.beginCheckpointRecovery(saved))
        var registry = registry()
        publish(registry, to: engine)
        registry.cancel(id: .number(7), method: "approval", sessionID: "s", generation: 3)
        registry.receive(id: .string("replacement"), method: "clarify", params: .object([
            "session_id": .string("s"), "questions": .array([
                .object(["qid": .string("a"), "question": .string("First")]),
                .object(["qid": .string("b"), "question": .string("Second")])])]), generation: 3)
        let current = try XCTUnwrap(registry.open(in: "s").first)
        registry.lock(current.identity, questionID: "a", answer: "Synthetic accepted answer")
        publish(registry, to: engine)
        XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: replay([
            event("message.complete", sequence: 101), event("message.start", sequence: 102)]), checkpoint: saved))
        XCTAssertTrue(engine.state(for: "s").pendingApprovals.isEmpty)
        XCTAssertEqual(engine.state(for: "s").clarify?.serverRequest, current.identity)
        XCTAssertEqual(engine.state(for: "s").clarify?.lockedAnswers, ["a": "Synthetic accepted answer"])
    }

    func testExplicitResetAndForgetDropCurrentProjectionButPreservingResetKeepsIt() throws {
        for reset in ["drop", "forget", "preserve"] {
            let saved = try checkpoint()
            let engine = TurnEngine()
            engine.setReplayEpoch("epoch")
            publish(registry(), to: engine)
            if reset == "forget" { engine.forget(sessionID: "s") }
            else { engine.reset(sessionID: "s", preserveServerRequests: reset == "preserve") }
            XCTAssertTrue(engine.beginCheckpointRecovery(saved))
            XCTAssertTrue(engine.finishEventRecovery(sessionID: "s", replay: replay(), checkpoint: saved))
            XCTAssertEqual(engine.state(for: "s").hasBlockingPrompt, reset == "preserve", reset)
        }
    }
}


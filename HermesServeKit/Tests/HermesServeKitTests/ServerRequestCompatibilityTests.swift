import XCTest
@testable import HermesServeKit

final class ServerRequestCompatibilityTests: XCTestCase {
    private func params(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["session_id": .string("session")].merging(extra) { _, new in new })
    }
    private func entry(_ id: JSONValue = .string("one"), method: String = "clarify", extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["id": id, "method": .string(method), "params": params(extra)])
    }

    func testCurrentResumeCompatibilitySummaryCannotCreateALegacyFIFOApproval() {
        let summary: JSONValue = .object(["command": .string("echo synthetic")])
        let current = SessionAPI.decodeResume(.object(["session_id": .string("session"),
            "pending_approval": summary, "open_requests": .array([entry(method: "approval")])]), requested: "stored")
        XCTAssertNil(current.pendingApproval)
        let negotiated = SessionAPI.decodeResume(.object(["session_id": .string("session"),
            "pending_approval": summary]), requested: "stored", includeLegacyPrompts: false)
        XCTAssertNil(negotiated.pendingApproval)
        let legacy = SessionAPI.decodeResume(.object(["session_id": .string("session"),
            "pending_approval": summary]), requested: "stored")
        XCTAssertEqual(legacy.pendingApproval?.command, "echo synthetic")
    }

    func testIdentifiedLegacyApprovalsDeduplicateByIDNotRepeatedCommandText() {
        let engine = TurnEngine()
        for id in ["one", "one", "two"] {
            engine.apply(GatewayEvent(type: "approval.request", sessionID: "session", payload: .object([
                "request_id": .string(id), "command": .string("echo same")]), params: .null))
        }
        XCTAssertEqual(engine.state(for: "session").pendingApprovals.map(\.legacyRequestID), ["one", "two"])
        let snapshot = SessionAPI.decodeResume(.object(["session_id": .string("session"), "running": .bool(true),
            "pending_approval": .object(["request_id": .string("three"), "command": .string("echo same")])]), requested: "stored")
        // Ordinary resume seeds the busy state; replay-preserving resume intentionally
        // refuses snapshot prompts after replay has already made the turn terminal.
        engine.applyResumeProjection(sessionID: "session", result: snapshot, trailingUserTexts: [])
        engine.applyResumeProjection(sessionID: "session", result: snapshot, trailingUserTexts: [])
        XCTAssertEqual(engine.state(for: "session").pendingApprovals.map(\.legacyRequestID), ["one", "two", "three"])
    }

    func testFreshPeerRevertAdvancesTheProjectionRevisionWithoutReorderingCards() throws {
        var registry = ServerRequestRegistry()
        let originalParams = params(["answers": .object(["a": .string("A")])])
        registry.receive(id: .string("one"), method: "clarify", params: originalParams, generation: 1)
        registry.receive(id: .string("two"), method: "clarify", params: params(), generation: 1)
        let initial = try XCTUnwrap(registry.open(in: "session").first)
        let queuedBeforeLock = registry.beginSnapshot()
        registry.lock(initial.identity, questionID: "a", answer: "B")
        let accepted = try XCTUnwrap(registry.open(in: "session").first)
        let originalEntries = [entry(extra: ["answers": .object(["a": .string("A")])]), entry(.string("two"))]
        registry.reconcile(originalEntries, sessionID: "session", generation: 1, startedAt: queuedBeforeLock)
        XCTAssertEqual(registry.open(in: "session").first?.clarify?.lockedAnswers, ["a": "B"])

        let fresh = registry.beginSnapshot()
        registry.reconcile(originalEntries, sessionID: "session", generation: 1, startedAt: fresh)
        let reverted = try XCTUnwrap(registry.open(in: "session").first)
        XCTAssertEqual(reverted.clarify?.lockedAnswers, ["a": "A"])
        XCTAssertEqual(reverted.clarify?.sourceRevision, fresh)
        XCTAssertGreaterThan(reverted.revision, accepted.revision)
        XCTAssertNotEqual(reverted.clarify, initial.clarify, "freshness must survive A-to-B-to-A even if B never renders")
        XCTAssertEqual(reverted.id, initial.id)
        XCTAssertEqual(reverted.order, initial.order)
        XCTAssertEqual(registry.open(in: "session").map(\.identity.id), [.string("one"), .string("two")])

        let unchanged = registry.beginSnapshot()
        registry.reconcile(originalEntries, sessionID: "session", generation: 1, startedAt: unchanged)
        XCTAssertEqual(registry.open(in: "session").first?.clarify, reverted.clarify,
                       "identical polls must not manufacture projection changes")
    }

    func testLegacyPayloadCannotForgeAClientSourceRevision() {
        let legacy = ClarifyRequestEvent(sessionID: "session", payload: .object([
            "request_id": .string("legacy"), "question": .string("Question"), "source_revision": .number(999)]))
        XCTAssertNil(legacy.sourceRevision)
    }

    func testPartialAnswerDoesNotMoveItsCardBehindAnotherQuestion() throws {
        var registry = ServerRequestRegistry()
        registry.receive(id: .string("first"), method: "clarify", params: params(), generation: 1)
        registry.receive(id: .string("second"), method: "clarify", params: params(), generation: 1)
        let first = try XCTUnwrap(registry.open(in: "session").first)
        registry.lock(first.identity, questionID: "a", answer: "synthetic")
        XCTAssertEqual(registry.open(in: "session").map(\.identity.id), [.string("first"), .string("second")])
    }

    func testTypedIDsAndSameQuestionTextRemainDistinct() {
        var registry = ServerRequestRegistry()
        for id: JSONValue in [.number(7), .string("7"), .string("other")] {
            registry.receive(id: id, method: "clarify", params: params(["question": .string("same")]), generation: 1)
        }
        XCTAssertEqual(registry.open(in: "session").count, 3)
        XCTAssertNotEqual(ServerRequestID(.number(7)), ServerRequestID(.string("7")))
    }

    func testLiveAndSnapshotDeduplicateByIdentityAndKeepApprovalUUID() throws {
        var registry = ServerRequestRegistry()
        let start = registry.beginSnapshot()
        registry.receive(id: .string("one"), method: "approval", params: params(), generation: 1)
        let before = try XCTUnwrap(registry.open(in: "session").first)
        registry.reconcile([entry(method: "approval")], sessionID: "session", generation: 1, startedAt: start)
        let after = try XCTUnwrap(registry.open(in: "session").first)
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(after.approval?.id, before.id)
        XCTAssertEqual(registry.open(in: "session").count, 1)
    }

    func testCancelBeforeSnapshotCannotResurrectAndOnlyMatchesExactMethod() {
        var registry = ServerRequestRegistry()
        registry.receive(id: .string("one"), method: "clarify", params: params(), generation: 1)
        registry.receive(id: .string("two"), method: "clarify", params: params(), generation: 1)
        let start = registry.beginSnapshot()
        registry.cancel(id: .string("one"), method: "sudo", sessionID: "session", generation: 1)
        XCTAssertEqual(registry.open(in: "session").count, 2)
        registry.cancel(id: .string("one"), method: "clarify", sessionID: "session", generation: 1)
        registry.reconcile([entry(), entry(.string("two"))], sessionID: "session", generation: 1, startedAt: start)
        XCTAssertEqual(registry.open(in: "session").map(\.identity.id), [.string("two")])
    }

    func testSnapshotAbsenceRetiresOtherClientsAnswerButKeepsLaterLiveRequest() {
        var registry = ServerRequestRegistry()
        registry.receive(id: .string("old"), method: "clarify", params: params(), generation: 1)
        let start = registry.beginSnapshot()
        registry.receive(id: .string("new"), method: "clarify", params: params(), generation: 1)
        registry.reconcile([], sessionID: "session", generation: 1, startedAt: start)
        XCTAssertEqual(registry.open(in: "session").map(\.identity.id), [.string("new")])
        registry.reconcile([entry(.string("old"))], sessionID: "session", generation: 1, startedAt: start)
        XCTAssertEqual(registry.open(in: "session").map(\.identity.id), [.string("new")])
    }

    func testOutOfOrderSnapshotsCannotEraseBatchLocks() throws {
        var registry = ServerRequestRegistry()
        registry.receive(id: .string("one"), method: "clarify", params: params(), generation: 1)
        let old = registry.beginSnapshot()
        let new = registry.beginSnapshot()
        registry.reconcile([entry(extra: ["answers": .object(["a": .string("first")])])], sessionID: "session", generation: 1, startedAt: new)
        registry.reconcile([entry()], sessionID: "session", generation: 1, startedAt: old)
        let request = try XCTUnwrap(registry.open(in: "session").first)
        XCTAssertEqual(request.clarify?.lockedAnswers, ["a": "first"])
        let later = registry.beginSnapshot()
        registry.lock(request.identity, questionID: "b", answer: "second")
        registry.reconcile([entry()], sessionID: "session", generation: 1, startedAt: later)
        XCTAssertEqual(registry.open(in: "session").first?.clarify?.lockedAnswers, ["a": "first", "b": "second"])
    }

    func testReconnectGetsNewIdentityAndRestoresAcceptedBatchAnswers() throws {
        var registry = ServerRequestRegistry()
        registry.receive(id: .string("one"), method: "clarify", params: params(), generation: 1)
        let old = try XCTUnwrap(registry.open(in: "session").first)
        registry.reset()
        let start = registry.beginSnapshot()
        registry.reconcile([entry(extra: ["answers": .object(["a": .string("first")])])], sessionID: "session", generation: 2, startedAt: start)
        let new = try XCTUnwrap(registry.open(in: "session").first)
        XCTAssertNotEqual(old.identity, new.identity)
        XCTAssertEqual(new.clarify?.lockedAnswers, ["a": "first"])
    }

    func testAllOfficialRequestsHaveAnExplicitPresentationAndNoAutomaticAction() throws {
        for method in ["approval", "clarify", "sudo", "secret", "vault.unlock_prompt", "vault.code", "vault.save_login", "terminal.read", "preview.read", "preview.act", "window.read", "tour", "future.method"] {
            var registry = ServerRequestRegistry()
            registry.receive(id: .string("one"), method: method, params: params(), generation: 1)
            let request = try XCTUnwrap(registry.open(in: "session").first)
            XCTAssertTrue(request.approval != nil || request.clarify != nil || request.sudo != nil || request.secret != nil, method)
            XCTAssertEqual(request.secret?.requiresDesktop ?? false, request.requiresDesktop, method)
            XCTAssertEqual(registry.open(in: "session").count, 1, "Projection must never settle a request")
        }
    }

    func testTransportRequestProjectionSurvivesResumeResetAndClearsOnlyCurrentPrompts() throws {
        var registry = ServerRequestRegistry()
        registry.receive(id: .string("one"), method: "approval", params: params(), generation: 1)
        let engine = TurnEngine()
        engine.apply(GatewayEvent(type: "approval.request", sessionID: "session", payload: .object(["command": .string("legacy")]), params: .null))
        engine.apply(GatewayEvent(type: "client.server_requests", sessionID: "session", payload: .null, params: .null, serverRequests: registry.open(in: "session")))
        XCTAssertEqual(engine.state(for: "session").pendingApprovals.count, 2)
        engine.reset(sessionID: "session", preserveServerRequests: true)
        XCTAssertEqual(engine.state(for: "session").pendingApprovals.count, 1)
        XCTAssertNotNil(engine.state(for: "session").currentApproval?.serverRequest)
        engine.apply(GatewayEvent(type: "client.server_requests", sessionID: "session", payload: .null, params: .null, serverRequests: []))
        XCTAssertFalse(engine.state(for: "session").hasBlockingPrompt)
    }
}

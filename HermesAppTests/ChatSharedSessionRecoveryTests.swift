import Foundation
import XCTest
@testable import HermesServeKit
@testable import HermesMobile

@MainActor
final class ChatSharedSessionRecoveryTests: XCTestCase {
    func testColdOpenRestoresDiskTimelineThenReplaysWithoutDuplicatingResumeText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptStore(root: root)
        let previous = TurnEngine()
        previous.setReplayEpoch("epoch")
        for row in [frame("runtime", "message.start", "", 1),
                    frame("runtime", "reasoning.delta", "Thinking", 2),
                    frame("runtime", "message.delta", "Before", 3)] {
            previous.apply(GatewayEvent(type: row["type"]!.text, sessionID: "runtime",
                payload: row["payload"]!, params: row))
        }
        let checkpoint = try XCTUnwrap(previous.checkpoint(sessionID: "runtime"))
        let h = await AppHarness.make()
        try await h.openSocket()
        h.app.engine.setReplayEpoch("epoch")
        let chat = h.chat(storedID: "stored")
        chat.transcriptStore = store
        let key = try XCTUnwrap(chat.checkpointKey)
        let now = Date()
        await store.save(.init(savedAt: now, history: [ChatEntry(id: "persisted", kind: .user, text: "Question")],
            ordinals: ["persisted": 1], turn: checkpoint), key: key, at: now)
        let loaded = await store.load(key: key)
        XCTAssertNotNil(loaded)
        await h.backend.stub("session.resume") { _ in .object([
            "session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true),
            "info": .object([:]), "inflight": .object(["user": .string("Question"),
                "assistant": .string("BeforeAfter"), "streaming": .bool(true)])]) }
        let missed = frame("runtime", "message.delta", "After", 4)
        await h.backend.stub("session.events.since") { params in
            XCTAssertEqual(params.params["last_seen"]?.coercedInt, 3)
            return .object(["epoch": .string("epoch"), "truncated": .bool(false), "events": .array([missed])])
        }
        await chat.open()
        XCTAssertEqual(chat.entries.map(\.text), ["Question", "BeforeAfter"])
        XCTAssertEqual(chat.entries.last?.reasoning, "Thinking")
        XCTAssertTrue(chat.isBusy)
        let submissions = await h.backend.callCount("prompt.submit")
        XCTAssertEqual(submissions, 0)
        let otherScope = await store.load(key: key + "other-backend")
        XCTAssertNil(otherScope)
        await store.removeBackend(h.profileID)
        await store.save(loaded, key: key, at: now) // A queued write from before sign-out cannot revive it.
        let afterSignOut = await store.load(key: key)
        XCTAssertNil(afterSignOut)
        await h.tearDown()
    }

    private func frame(_ sid: String, _ type: String, _ text: String, _ seq: Int) -> JSONValue {
        .object(["session_id": .string(sid), "type": .string(type), "seq": .number(Double(seq)),
                 "payload": .object(["text": .string(text)])])
    }
    private func paint(_ app: AppModel, _ row: JSONValue) {
        app.engine.apply(GatewayEvent(type: row["type"]!.text, sessionID: row["session_id"]!.text,
                                     payload: row["payload"]!, params: row))
        app.engine.flush()
        app.publish(sessionID: row["session_id"]!.text)
    }
    func testReturnOnOpenSocketReattachesAndReplaysWithoutSubmittingOrResuming() async throws {
        let h = await AppHarness.make()
        try await h.openSocket()
        let chat = h.chat(storedID: "stored")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        h.app.engine.setReplayEpoch("epoch")
        paint(h.app, frame(sid, "message.start", "", 1))
        paint(h.app, frame(sid, "message.delta", "Before", 2))
        let complete = frame(sid, "message.complete", "BeforeAfter", 4)
        let delta = frame(sid, "message.delta", "After", 3)
        await h.backend.stub("session.activate") { _ in .object(["session_id": .string(sid)]) }
        await h.backend.stub("session.events.since") { _ in .object([
            "epoch": .string("epoch"), "truncated": .bool(false), "events": .array([delta, complete])]) }
        let resumes = await h.backend.callCount("session.resume")
        await chat.openIfNeeded()
        XCTAssertEqual(chat.entries.filter { $0.kind == .assistant }.map(\.text), ["BeforeAfter"])
        XCTAssertFalse(chat.isBusy)
        let after = await h.backend.callCount("session.resume")
        let submits = await h.backend.callCount("prompt.submit")
        XCTAssertEqual(after, resumes)
        XCTAssertEqual(submits, 0)
        await h.tearDown()
    }
    func testConcurrentReturnJoinsOneRecoveryAndPreservesFramesDuringReplay() async throws {
        let h = await AppHarness.make()
        try await h.openSocket()
        let chat = h.chat(storedID: "stored")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        h.app.engine.setReplayEpoch("epoch")
        paint(h.app, frame(sid, "message.start", "", 1))
        await h.backend.stub("session.activate") { _ in .object(["session_id": .string(sid)]) }
        let delta = frame(sid, "message.delta", "A", 2)
        await h.backend.stub("session.events.since") { _ in .object([
            "epoch": .string("epoch"), "truncated": .bool(false), "events": .array([delta])]) }
        await h.backend.gate("session.events.since")
        let first = Task { await chat.resumeAfterReconnect(force: true) }
        let waiting = await waitUntil { await h.backend.callCount("session.events.since") == 1 }
        XCTAssertTrue(waiting)
        let second = Task { await chat.resumeAfterReconnect(force: true) }
        paint(h.app, frame(sid, "message.delta", "B", 3))
        await h.backend.ungate("session.events.since")
        await h.backend.releaseParked()
        await first.value
        await second.value
        XCTAssertEqual(chat.entries.last?.text, "AB")
        let calls = await h.backend.callCount("session.events.since")
        XCTAssertEqual(calls, 1)
        await h.tearDown()
    }
    func testOfficialBackendWithoutReplayReattachesWithoutRecreatingAgent() async throws {
        let h = await AppHarness.make()
        try await h.openSocket()
        let chat = h.chat(storedID: "stored")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        await h.backend.stub("session.activate") { _ in .object(["session_id": .string(sid)]) }
        let before = await h.backend.callCount("session.resume")
        await chat.openIfNeeded()
        let after = await h.backend.callCount("session.resume")
        XCTAssertEqual(after, before)
        let submits = await h.backend.callCount("prompt.submit")
        XCTAssertEqual(submits, 0)
        await h.tearDown()
    }
    func testLateActivationSnapshotCannotEraseNewLiveOutput() async throws {
        let h = await AppHarness.make()
        try await h.openSocket()
        let chat = h.chat(storedID: "stored")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        await h.backend.stub("session.activate") { _ in .object([
            "session_id": .string(sid), "running": .bool(true),
            "inflight": .object(["user": .string("hello"), "assistant": .string("old"), "streaming": .bool(true)])]) }
        await h.backend.gate("session.activate")
        let returning = Task { await chat.openIfNeeded() }
        let waiting = await waitUntil { await h.backend.callCount("session.activate") == 1 }
        XCTAssertTrue(waiting)
        await h.backend.emitAssistantText("new output", sessionID: sid)
        let received = await waitUntil { chat.entries.contains { $0.text == "new output" } }
        XCTAssertTrue(received)
        await h.backend.ungate("session.activate")
        await h.backend.releaseParked()
        await returning.value
        XCTAssertTrue(chat.entries.contains { $0.text == "new output" })
        XCTAssertFalse(chat.entries.contains { $0.text == "old" })
        await h.tearDown()
    }
    func testObservedSubmissionSurvivesAnUnsuccessfulReplyWithoutRetry() async throws {
        let h = await AppHarness.make()
        try await h.openSocket()
        let chat = h.chat(storedID: "stored")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        h.app.engine.setSharedSession(.object(["version": .number(1), "socket_id": .string("phone")]))
        await h.backend.gate("prompt.submit")
        chat.draft = "hello"
        chat.sendTapped()
        let sent = await waitUntil { await h.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(sent)
        let calls = await h.backend.calls(to: "prompt.submit")
        let ref = try XCTUnwrap(calls.first?.params["submission_ref"]?.coercedString)
        let payload: JSONValue = .object(["input": .object(["role": .string("user"), "text": .string("hello")]),
            "inputs": .array([.object(["id": .string("input"), "ref": .string(ref)])]), "inputs_complete": .bool(true)])
        h.app.engine.apply(GatewayEvent(type: "message.start", sessionID: sid, payload: payload, params: .object([
            "turn": .object(["id": .string("run"), "source": .object(["kind": .string("unknown")])])
        ])))
        h.app.publish(sessionID: sid)
        await h.backend.failRPC("prompt.submit", code: -32603, message: "reply unavailable")
        await h.backend.ungate("prompt.submit")
        await h.backend.releaseParked()
        let settled = await waitUntil { !chat.isSending }
        XCTAssertTrue(settled)
        XCTAssertEqual(chat.entries.filter { $0.kind == .user && $0.text == "hello" }.count, 1)
        XCTAssertTrue(chat.outbound.isEmpty)
        XCTAssertEqual(chat.live.turnOwnership, .local)
        let count = await h.backend.callCount("prompt.submit")
        XCTAssertEqual(count, 1)
        await h.tearDown()
    }
}

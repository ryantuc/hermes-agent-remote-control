import HermesServeKit
import XCTest
@testable import HermesMobile

@MainActor
final class CurrentServerRequestAppTests: XCTestCase {
    private func setup() async throws -> (AppHarness, ChatModel, String) {
        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.stub("client.capabilities") { _ in .object(["server_requests": .array([.string("approval"), .string("clarify"), .string("secret")])]) }
        try await harness.openSocket()
        let chat = harness.chat(storedID: "synthetic-current-requests")
        await chat.open()
        let sid = try XCTUnwrap(chat.runtimeSessionID)
        chat.errorMessage = nil
        return (harness, chat, sid)
    }

    func testCurrentApprovalQueueAnswersExactRequestWithoutLegacyFIFO() async throws {
        let (harness, chat, sid) = try await setup()
        for id in ["one", "two"] {
            await harness.backend.emitServerRequest(id: id, method: "approval", sessionID: sid, params: ["request_id": .string("queue-" + id), "command": .string("echo synthetic"), "choices": .array([.string("once"), .string("deny")])])
        }
        let queued = await waitUntil { chat.live.pendingApprovals.count == 2 }
        XCTAssertTrue(queued)
        let first = try XCTUnwrap(chat.pendingApproval)
        await chat.respond(to: first, choice: .once)
        let next = await waitUntil { chat.pendingApproval?.serverRequest?.id == .string("two") }
        XCTAssertTrue(next)
        let replies = await harness.backend.receivedResponses
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.id, .string("one"))
        XCTAssertEqual(replies.first?.result, .object(["choice": .string("once")]))
        let legacyCalls = await harness.backend.callCount("approval.respond")
        XCTAssertEqual(legacyCalls, 0)
        await harness.tearDown()
    }

    func testUnsupportedPromptIsInertAndMinimizableUntilExplicitGlobalSkip() async throws {
        let (harness, chat, sid) = try await setup()
        await harness.backend.emitServerRequest(id: "desktop", method: "vault.save_login", sessionID: sid, params: ["site": .string("example.invalid"), "origin": .string("https://example.invalid")])
        let shown = await waitUntil { chat.pendingSecret?.requiresDesktop == true }
        XCTAssertTrue(shown)
        XCTAssertNil(chat.presentedBlockingPrompt(minimised: true))
        let before = await harness.backend.receivedResponses
        XCTAssertTrue(before.isEmpty)
        let card = try XCTUnwrap(chat.pendingSecret)
        await chat.respondSecret("", requestID: card.id)
        let replies = await harness.backend.receivedResponses
        XCTAssertEqual(replies.first?.id, .string("desktop"))
        XCTAssertEqual(replies.first?.result, .object(["value": .string("")]))
        XCTAssertFalse(chat.hasBlockingPrompt)
        await harness.tearDown()
    }

    func testCancellationOnlyRemovesMatchingCurrentCardAndStaleUIIsInert() async throws {
        let (harness, chat, sid) = try await setup()
        await harness.backend.emitServerRequest(id: "question", method: "clarify", sessionID: sid, params: ["question": .string("Synthetic question")])
        let shown = await waitUntil { chat.pendingClarify != nil }
        XCTAssertTrue(shown)
        let old = try XCTUnwrap(chat.pendingClarify)
        await harness.backend.emit("request.cancel", sessionID: sid, payload: .object(["id": .string("other"), "method": .string("clarify"), "reason": .string("timeout")]))
        XCTAssertNotNil(chat.pendingClarify)
        await harness.backend.emit("request.cancel", sessionID: sid, payload: .object(["id": .string("question"), "method": .string("clarify"), "reason": .string("timeout")]))
        let removed = await waitUntil { chat.pendingClarify == nil }
        XCTAssertTrue(removed)
        await chat.respondClarify("late", requestID: old.id)
        let replies = await harness.backend.receivedResponses
        XCTAssertTrue(replies.isEmpty)
        await harness.tearDown()
    }

    func testCurrentResumeSummaryCannotCreateDuplicateLegacyApproval() async throws {
        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.stub("client.capabilities") { _ in .object(["server_requests": .array([.string("approval")])]) }
        await harness.backend.stub("session.resume") { call in .object([
            "session_id": .string("current-runtime"), "session_key": .string(call.sessionID),
            "resumed": .string(call.sessionID), "running": .bool(true), "status": .string("working"),
            "messages": .array([]), "info": ScriptedBackend.info(),
            "pending_approval": .object(["command": .string("echo synthetic")]),
            "open_requests": .array([.object(["id": .string("replayed-approval"), "method": .string("approval"), "params": .object([
                "session_id": .string("current-runtime"), "request_id": .string("queue-entry"), "command": .string("echo synthetic"),
                "choices": .array([.string("once"), .string("deny")])])])])]) }
        try await harness.openSocket()
        let chat = harness.chat(storedID: "synthetic-resume-approval")
        await chat.open()
        let restored = await waitUntil { chat.pendingApproval?.serverRequest?.id == .string("replayed-approval") }
        XCTAssertTrue(restored)
        XCTAssertEqual(chat.live.pendingApprovals.count, 1)
        let approval = try XCTUnwrap(chat.pendingApproval)
        await chat.respond(to: approval, choice: .once)
        let legacyCalls = await harness.backend.callCount("approval.respond")
        XCTAssertEqual(legacyCalls, 0)
        await harness.tearDown()
    }

    func testResumeSnapshotReachesUIAfterTranscriptReset() async throws {
        let harness = await AppHarness.make(handlesServerRequests: true)
        await harness.backend.stub("session.resume") { call in .object([
            "session_id": .string("current-runtime"), "session_key": .string(call.sessionID),
            "resumed": .string(call.sessionID), "running": .bool(true), "status": .string("working"),
            "messages": .array([]), "info": ScriptedBackend.info(), "open_requests": .array([
                .object(["id": .string("replayed"), "method": .string("secret"), "params": .object([
                    "session_id": .string("current-runtime"), "prompt": .string("Synthetic credential"), "env_var": .string("SYNTHETIC_VALUE")])])])]) }
        try await harness.openSocket()
        let chat = harness.chat(storedID: "synthetic-resume")
        await chat.open()
        let restored = await waitUntil { chat.pendingSecret?.serverRequest?.id == .string("replayed") }
        XCTAssertTrue(restored)
        XCTAssertTrue(chat.hasBlockingPrompt)
        await harness.tearDown()
    }
}

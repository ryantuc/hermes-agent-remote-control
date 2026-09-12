import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-026 — clarify/sudo/secret answers must bind to the request the sheet
/// was rendered for. Approval already guards `live.currentApproval?.id ==
/// approval.id`; the other three read whatever is live at tap time.
@MainActor
final class ChatModelStalePromptGuardTests: XCTestCase {

    func testClarifyAnswerDoesNotFollowASwap() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_026000_staleclarify")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-A"),
            "question": .string("First question?"),
        ]))
        let first = await waitUntil { chat.live.clarify?.id == "q-A" }
        XCTAssertTrue(first, "clarify A never parked")

        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-B"),
            "question": .string("Second question?"),
        ]))
        let swapped = await waitUntil { chat.live.clarify?.id == "q-B" }
        XCTAssertTrue(swapped, "clarify B never replaced A — the rest of this test proves nothing")

        await chat.respondClarify("answer typed for A", requestID: "q-A")
        let calls = await harness.backend.calls(to: "clarify.respond")
        XCTAssertTrue(
            calls.isEmpty,
            "respondClarify read live.clarify at tap time and delivered A's answer to B (request_id=\(calls.last?.params["request_id"]?.coercedString ?? "?"))"
        )

        await harness.tearDown()
    }

    func testMatchingClarifyIdStillSends() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_026001_liveclarify")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-live"),
            "question": .string("Still this one?"),
        ]))
        let parked = await waitUntil { chat.live.clarify?.id == "q-live" }
        XCTAssertTrue(parked, "the clarify never parked")

        await chat.respondClarify("yes", requestID: "q-live")
        let sent = await waitUntil { await harness.backend.callCount("clarify.respond") == 1 }
        XCTAssertTrue(sent, "a matching request id must still send")
        let calls = await harness.backend.calls(to: "clarify.respond")
        let call = try XCTUnwrap(calls.last)
        XCTAssertEqual(call.params["request_id"]?.coercedString, "q-live")
        XCTAssertEqual(call.params["answer"]?.coercedString, "yes")

        await harness.tearDown()
    }

    func testSecretAnswerDoesNotFollowASwap() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_026002_stalesecret")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("secret.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("s-A"),
            "prompt": .string("API key for A"),
            "env_var": .string("A_KEY"),
        ]))
        let first = await waitUntil { chat.live.secret?.id == "s-A" }
        XCTAssertTrue(first, "secret A never parked")

        await harness.backend.emit("secret.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("s-B"),
            "prompt": .string("API key for B"),
            "env_var": .string("B_KEY"),
        ]))
        let swapped = await waitUntil { chat.live.secret?.id == "s-B" }
        XCTAssertTrue(swapped, "secret B never replaced A — the rest of this test proves nothing")

        await chat.respondSecret("typed-for-A", requestID: "s-A")
        let calls = await harness.backend.calls(to: "secret.respond")
        XCTAssertTrue(
            calls.isEmpty,
            "respondSecret must not deliver A's credential to B (request_id=\(calls.last?.params["request_id"]?.coercedString ?? "?"))"
        )

        await harness.tearDown()
    }

    func testSudoAnswerDoesNotFollowASwap() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_026003_stalesudo")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("sudo.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("u-A"),
        ]))
        let first = await waitUntil { chat.live.sudo?.id == "u-A" }
        XCTAssertTrue(first, "sudo A never parked")

        await harness.backend.emit("sudo.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("u-B"),
        ]))
        let swapped = await waitUntil { chat.live.sudo?.id == "u-B" }
        XCTAssertTrue(swapped, "sudo B never replaced A — the rest of this test proves nothing")

        await chat.respondSudo("password-for-A", requestID: "u-A")
        let calls = await harness.backend.calls(to: "sudo.respond")
        XCTAssertTrue(
            calls.isEmpty,
            "respondSudo must not deliver A's password to B (request_id=\(calls.last?.params["request_id"]?.coercedString ?? "?"))"
        )

        await harness.tearDown()
    }
}

import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Desktop parity at the chat: a `connection.request` the agent is blocked on reaches the chat as a card, the status line says the turn is waiting on the person, and Skip / Continue answer through `connection.respond` by `op_id` (live contract `tui_gateway/contracts/connectors_operation.py:186-238`).
@MainActor
final class ConnectionCardModelTests: XCTestCase {
    private func harness() async throws -> (AppHarness, ChatModel, String) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261002_connect")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        return (harness, chat, chat.runtimeSessionID ?? "")
    }

    private func request(op: String = "op-1") -> JSONValue {
        .object([
            "op_id": .string(op), "seq": .number(1), "deadline_at": .number(Date().timeIntervalSince1970 + 300),
            "timeout_seconds": .number(300), "tool_call_id": .string("call_1"),
            "targets": .array([
                .object(["name": .string("github"), "kind": .string("connector"), "action": .string("connect"),
                         "state": .string("pending"), "connect_url": .string("https://connect.example.com/gh")]),
                .object(["name": .string("linear"), "kind": .string("connector"), "action": .string("connect"),
                         "state": .string("pending")]),
            ]),
        ])
    }

    private func openCard(_ harness: AppHarness, _ chat: ChatModel, _ sid: String) async {
        await harness.backend.emit("message.start", sessionID: sid)
        await harness.backend.emit("connection.request", sessionID: sid, payload: request())
        _ = await waitUntil { chat.pendingConnection != nil }
    }

    func testTheCardReachesTheChatAndTheStatusLineSaysWhy() async throws {
        let (harness, chat, sid) = try await harness()

        await openCard(harness, chat, sid)

        let card = try XCTUnwrap(chat.pendingConnection, "the card the agent is blocked on never reached the chat")
        XCTAssertEqual(card.targets.map(\.name), ["github", "linear"])
        XCTAssertEqual(chat.statusLineText, "Waiting for you to connect an app",
                       "the turn is parked on the person, not thinking")
        XCTAssertFalse(chat.hasBlockingPrompt, "the card is not an approval-sheet prompt")

        await harness.tearDown()
    }

    func testSkipAnswersByOperationID() async throws {
        let (harness, chat, sid) = try await harness()
        await harness.backend.stub("connection.respond") { _ in .object(["status": .string("ok"), "settled": .bool(false)]) }
        await openCard(harness, chat, sid)

        chat.skipConnectionTarget("linear")

        let answered = await waitUntil { await harness.backend.callCount("connection.respond") == 1 }
        XCTAssertTrue(answered, "Skip never reached the backend")
        let call = await harness.backend.calls(to: "connection.respond").first
        XCTAssertEqual(call?.params["op_id"]?.stringValue, "op-1")
        XCTAssertEqual(call?.params["owner"]?["session_id"]?.stringValue, sid)
        XCTAssertEqual(call?.params["result"]?["targets"]?.arrayValue?.first?["name"]?.stringValue, "linear")
        XCTAssertEqual(call?.params["result"]?["targets"]?.arrayValue?.first?["status"]?.stringValue, "skipped")
        let settledFlag = await waitUntil { !chat.isAnsweringConnection }
        XCTAssertTrue(settledFlag)

        await harness.tearDown()
    }

    func testContinueEndsTheOperationAndTheSettlementClosesTheCard() async throws {
        let (harness, chat, sid) = try await harness()
        await harness.backend.stub("connection.respond") { _ in .object(["status": .string("ok"), "settled": .bool(true)]) }
        await openCard(harness, chat, sid)

        chat.continueConnection()

        let answered = await waitUntil { await harness.backend.callCount("connection.respond") == 1 }
        XCTAssertTrue(answered)
        let call = await harness.backend.calls(to: "connection.respond").first
        XCTAssertEqual(call?.params["result"]?["settled_by"]?.stringValue, "continue")

        await harness.backend.emit("connection.update", sessionID: sid, payload: .object([
            "op_id": .string("op-1"), "seq": .number(3), "deadline_at": .number(0), "settled": .bool(true),
            "settled_by": .string("continue"), "owner": .object(["type": .string("session"), "session_id": .string(sid)]),
            "targets": .array([]),
        ]))
        let closed = await waitUntil { chat.pendingConnection == nil }
        XCTAssertTrue(closed, "the settled card stayed on screen")

        await harness.tearDown()
    }

    func testARefusedAnswerIsSaidAndTheCardStays() async throws {
        let (harness, chat, sid) = try await harness()
        await harness.backend.failRPC("connection.respond", code: 4004, message: "No open operation with that op_id.")
        await openCard(harness, chat, sid)

        chat.continueConnection()

        let reported = await waitUntil { chat.errorMessage?.contains("No open operation") == true }
        XCTAssertTrue(reported, "a refused answer was swallowed: \(chat.errorMessage ?? "nil")")
        XCTAssertNotNil(chat.pendingConnection, "only the backend's settlement closes the card")
        XCTAssertFalse(chat.isAnsweringConnection)

        await harness.tearDown()
    }
}

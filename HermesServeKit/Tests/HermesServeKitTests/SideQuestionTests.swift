import XCTest

@testable import HermesServeKit

/// `/btw`: `prompt.btw {session_id, text}` (`SideAgentParams`, `tui_gateway/contracts/prompt_voice.py:225-239`, `:222-223` on an older backend) replies `{task_id}` at once, and the answer arrives later as `btw.complete {task_id, text, question}` on the asking session (`tui_gateway/contracts/events.py:459-468`; emitter `tui_gateway/methods_prompt.py:965-984`, `:1207-1209`). The client had no handler for the event and listed the command as unavailable (`SlashCommandsAPI.swift`, `SlashCommandSupport.unavailable`).
final class SideQuestionTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func answer(_ text: String, question: String = "why did you pick sqlite?") -> GatewayEvent {
        let payload: JSONValue = .object([
            "task_id": .string("btw_1a2b3c"), "question": .string(question), "text": .string(text),
        ])
        return GatewayEvent(type: "btw.complete", sessionID: session, payload: payload, params: .object([
            "type": .string("btw.complete"), "session_id": .string(session), "payload": payload,
        ]))
    }

    func testTheQuestionGoesOutAsDeclared() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.btw": [.object(["task_id": .string("btw_1a2b3c")])],
        ])

        let taskID = try await PromptAPI(client: client).btw(sessionID: session, question: "why did you pick sqlite?")

        XCTAssertEqual(taskID, "btw_1a2b3c")
        let sent = await socket.sentParams("prompt.btw")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(Set(params.objectValue?.keys.map { $0 } ?? []), ["session_id", "text"])
        XCTAssertEqual(params["session_id"]?.stringValue, session)
        XCTAssertEqual(params["text"]?.stringValue, "why did you pick sqlite?")
        let submits = await socket.sentCount("prompt.submit")
        XCTAssertEqual(submits, 0, "a side question is not a turn")

        await client.disconnect()
    }

    /// Desktop shows the answer as a persistent system line headed by the question (`gateway-event/status.ts:146-170`).
    func testTheAnswerLandsAsASystemRowWithItsQuestion() throws {
        let engine = TurnEngine()
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .object([:]), params: .null))

        engine.apply(answer("Because the data is local and small."))

        let row = try XCTUnwrap(engine.state(for: session).entries.last, "the side answer never reached the chat")
        XCTAssertEqual(row.kind, .system)
        XCTAssertEqual(row.noticeKind, "btw")
        XCTAssertTrue(row.text.contains("why did you pick sqlite?"), row.text)
        XCTAssertTrue(row.text.contains("Because the data is local and small."), row.text)
        XCTAssertTrue(engine.state(for: session).isBusy, "a side answer must not end the running turn")
    }

    /// It is not the stopped turn's output, so the interrupt latch does not swallow it.
    func testAnAnswerAfterAStopStillArrives() {
        let engine = TurnEngine()
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .object([:]), params: .null))
        engine.markInterrupted(sessionID: session)

        engine.apply(answer("Still answered."))

        XCTAssertEqual(engine.state(for: session).entries.last?.noticeKind, "btw")
    }

    func testAnEmptyAnswerAddsNothing() {
        let engine = TurnEngine()
        engine.apply(answer("   "))
        XCTAssertFalse(engine.state(for: session).entries.contains { $0.noticeKind == "btw" })
    }

    func testBtwIsAvailableOnThePhone() {
        XCTAssertTrue(SlashCommandSupport.supports(name: "/btw"))
        XCTAssertTrue(SlashCommandSupport.supports(name: "btw", desktopAction: "local"),
                      "the phone runs it itself, whatever action Desktop's catalog names")
        XCTAssertFalse(SlashCommandSupport.supports(name: "/btw", desktopAction: "hidden"))
        XCTAssertNil(SlashCommandSupport.unavailableReason(name: "btw", entry: nil))
    }
}

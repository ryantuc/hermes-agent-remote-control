import Foundation
import XCTest

@testable import HermesServeKit

/// BUG-041 — `clarify.request` carries **two** shapes on one event name.
///
/// Since 0.20.5 the `clarify` tool can ask up to five independent questions in
/// one call, and its schema tells the model that form is "STRONGLY preferred".
/// The batch payload is `{"questions": [...], "request_id": rid}` with no
/// top-level `question` and no top-level `choices`, so a decoder that reads
/// only the historical keys produces `question: ""` / `choices: []` — a blank
/// card rather than a decode error. And the reply has to carry the per-question
/// `question_id`, because a `clarify.respond` without one is the backend's
/// deliberate cancel-all path: the batch tail hands the raw string to the tool,
/// `json.loads` fails, and every question is reported to the agent as skipped.
///
/// Nothing on the wire was added, removed or renamed for any of this, and
/// `DESKTOP_BACKEND_CONTRACT` did not bump — which is why these are decode and
/// request-shape tests rather than a surface check.
final class BatchClarifyTests: XCTestCase {

    // MARK: - Decoding the batch shape

    /// The whole list survives, with each question's own address, text, choices
    /// and multi-select flag.
    func testBatchPayloadDecodesEveryQuestion() throws {
        let event = projectClarify(payload: .object([
            "request_id": .string("clr-1"),
            "questions": .array([
                .object([
                    "qid": .string("q0"),
                    "question": .string("Which deployment target?"),
                    "choices": .array([.string("staging (Recommended)"), .string("prod")]),
                    "multi_select": .bool(false),
                ]),
                .object([
                    "qid": .string("q1"),
                    "question": .string("Which regions?"),
                    "choices": .array([.string("us-east"), .string("eu-west")]),
                    "multi_select": .bool(true),
                ]),
                .object([
                    "qid": .string("q2"),
                    "question": .string("Anything else I should know?"),
                    // Open-ended entries send an explicit null, not an omission.
                    "choices": .null,
                    "multi_select": .bool(false),
                ]),
            ]),
        ]))

        XCTAssertTrue(event.isBatch, "a payload carrying `questions` must decode as a batch")
        XCTAssertEqual(event.questions.map(\.id), ["q0", "q1", "q2"],
                       "the qid is the backend's address for the answer and must survive verbatim")
        // Indexed below, so stop here rather than trap the whole suite.
        guard event.questions.count == 3 else { return }
        XCTAssertEqual(event.questions[0].question, "Which deployment target?")
        XCTAssertEqual(event.questions[0].choices, ["staging (Recommended)", "prod"])
        XCTAssertFalse(event.questions[0].multiSelect)
        XCTAssertTrue(event.questions[1].multiSelect)
        XCTAssertTrue(event.questions[2].choices.isEmpty,
                      "a null choices list is open-ended, not a broken choice list")
        XCTAssertFalse(event.questions[2].multiSelect,
                       "multi_select is meaningless without choices to select among")

        // The batch payload genuinely has neither key. Inventing a headline out
        // of the first question would be a lie about the wire, and the card
        // renders from `questions`.
        XCTAssertTrue(event.question.isEmpty)
        XCTAssertTrue(event.choices.isEmpty)
        XCTAssertEqual(event.id, "clr-1")
    }

    /// An entry with no address cannot be answered — `clarify.respond` refuses
    /// an unknown `question_id` with 4002 — so it is dropped rather than
    /// rendered as a row that can never be sent. Same two drops the reference
    /// desktop client makes (`apps/desktop/src/store/clarify.ts`).
    func testUnaddressableEntriesAreDropped() throws {
        let event = projectClarify(payload: .object([
            "request_id": .string("clr-2"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("Real question?")]),
                .object(["qid": .string(""), "question": .string("No address")]),
                .object(["qid": .string("q2"), "question": .string("   ")]),
                .string("not an object at all"),
            ]),
        ]))

        XCTAssertEqual(event.questions.map(\.id), ["q0"])
        XCTAssertTrue(event.isBatch)
    }

    /// The single-question shape is the common case and the backend still emits
    /// it byte-for-byte. Adding the batch path must not disturb it.
    func testSingleQuestionShapeIsUntouched() throws {
        let event = projectClarify(payload: .object([
            "request_id": .string("clr-3"),
            "question": .string("Rebase or merge?"),
            "choices": .array([.string("Rebase (Recommended)"), .string("Merge")]),
            "multi_select": .bool(true),
        ]))

        XCTAssertFalse(event.isBatch, "no `questions` key means the historical shape, not an empty batch")
        XCTAssertTrue(event.questions.isEmpty)
        XCTAssertEqual(event.question, "Rebase or merge?")
        XCTAssertEqual(event.choices, ["Rebase (Recommended)", "Merge"])
        XCTAssertTrue(event.multiSelect)
    }

    /// A reconnect during a batch replays the answers already locked
    /// (`_pending_clarify_request_payload` folds `answers` into the snapshot),
    /// so a returning card restores its per-question state instead of
    /// presenting everything as unanswered.
    func testReconnectReplayCarriesLockedAnswers() throws {
        let event = projectClarify(payload: .object([
            "request_id": .string("clr-4"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("Target?")]),
                .object(["qid": .string("q1"), "question": .string("Region?")]),
            ]),
            "answers": .object(["q0": .string("staging")]),
        ]))

        XCTAssertEqual(event.lockedAnswers, ["q0": "staging"])
    }

    /// Nothing replays on the ordinary first delivery, and an absent `answers`
    /// key must not read as "the backend holds an empty answer for everything".
    func testNoReplayMeansNoLockedAnswers() throws {
        let event = projectClarify(payload: .object([
            "request_id": .string("clr-5"),
            "questions": .array([.object(["qid": .string("q0"), "question": .string("Target?")])]),
        ]))
        XCTAssertTrue(event.lockedAnswers.isEmpty)
    }

    // MARK: - The reply

    /// Each locked answer goes out addressed by its qid, and the backend's
    /// `remaining` list comes back — it is exactly the progress a batch card
    /// needs, and an empty one is what says the turn has resumed.
    func testEachAnswerIsSentWithItsQuestionID() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "clarify.respond": [
                .object(["status": .string("ok"), "remaining": .array([.string("q1")])]),
                .object(["status": .string("ok"), "remaining": .array([])]),
            ]
        ])
        let api = ApprovalAPI(client: client)

        let first = try await api.respondClarify(requestID: "clr-1", answer: "staging", questionID: "q0")
        XCTAssertEqual(first.status, "ok")
        XCTAssertEqual(first.remaining, ["q1"], "the backend names the qids still outstanding")

        let last = try await api.respondClarify(requestID: "clr-1", answer: "us-east", questionID: "q1")
        XCTAssertEqual(last.remaining, [], "an empty remaining list is the final lock")

        let sent = try await sentRequests(socket, method: "clarify.respond")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["question_id"]?.coercedString, "q0",
                       "without question_id the answer falls past the per-question lock and is discarded")
        XCTAssertEqual(sent[0]["answer"]?.coercedString, "staging")
        XCTAssertEqual(sent[0]["request_id"]?.coercedString, "clr-1")
        XCTAssertEqual(sent[1]["question_id"]?.coercedString, "q1")
        XCTAssertEqual(sent[1]["answer"]?.coercedString, "us-east")

        await client.disconnect()
    }

    /// Cancel-all is defined by the **absence** of `question_id`, and the
    /// backend's own comment says so. A client that started attaching one
    /// unconditionally would have no way left to cancel a batch.
    func testCancelAllSendsNoQuestionID() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "clarify.respond": [.object(["status": .string("ok")])]
        ])
        let api = ApprovalAPI(client: client)

        let result = try await api.respondClarify(requestID: "clr-1", answer: "")
        XCTAssertEqual(result.status, "ok")
        XCTAssertNil(result.remaining,
                     "no `remaining` key is the backend making no claim, which is not the same as nothing left")

        let sent = try await sentRequests(socket, method: "clarify.respond")
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent[0]["question_id"], "cancel-all must stay a bare {request_id, answer}")
        XCTAssertEqual(sent[0]["answer"]?.coercedString, "")

        await client.disconnect()
    }

    /// An empty string is not an address. It must be treated as "no
    /// question_id" rather than sent as one, because `_respond` compares it
    /// against the batch's qid list.
    func testEmptyQuestionIDIsNotPutOnTheWire() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "clarify.respond": [.object(["status": .string("ok")])]
        ])
        _ = try await ApprovalAPI(client: client).respondClarify(
            requestID: "clr-1", answer: "", questionID: ""
        )

        let sent = try await sentRequests(socket, method: "clarify.respond")
        XCTAssertNil(sent[0]["question_id"])

        await client.disconnect()
    }

    // MARK: - Helpers

    private func projectClarify(payload: JSONValue) -> ClarifyRequestEvent {
        let params: JSONValue = .object([
            "type": .string("clarify.request"),
            "session_id": .string("sess-1"),
            "payload": payload,
        ])
        let gateway = GatewayEvent(
            type: "clarify.request",
            sessionID: "sess-1",
            payload: payload,
            params: params
        )
        guard case .clarifyRequest(let event) = HermesEvent.project(gateway) else {
            XCTFail("expected .clarifyRequest projection")
            return ClarifyRequestEvent(
                id: "", sessionID: "", question: "", choices: [], multiSelect: false
            )
        }
        return event
    }

    /// Every `params` object sent for `method`, oldest first. `sentParams` only
    /// answers for the most recent one, and a batch is defined by the sequence.
    private func sentRequests(
        _ socket: ScriptedGatewayTransport,
        method: String
    ) async throws -> [JSONValue] {
        let lines = await socket.sentLines
        return lines.compactMap { line -> JSONValue? in
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  value["method"]?.stringValue == method
            else { return nil }
            return value["params"]
        }
    }
}

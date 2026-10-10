import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-041 — the card's state machine for a **batch** clarify.
///
/// The backend does not treat a batch as "a single clarify with more rows". It
/// keeps every locked answer editable, calls the batch complete only when every
/// qid is in, and treats a `clarify.respond` with **no** `question_id` as a
/// deliberate cancel-all. Three consequences, one test each:
///
/// - answers are staged locally and nothing is sent until Confirm, because the
///   final lock is what resumes the turn;
/// - Confirm sends one request per question, each carrying its `question_id` —
///   the missing id is the whole defect, and the failure it produces is silent
///   at both ends;
/// - a deadline does not erase what already reached the backend.
@MainActor
final class BatchClarifyCardTests: XCTestCase {

    func testReconnectSkipsUnchangedLocksAndSendsEditedLocksBeforeFinalMissingAnswer() async {
        let request = ClarifyRequestEvent(id: "batch", sessionID: "session", question: "", choices: [], multiSelect: false,
            questions: [ClarifyQuestion(id: "missing", question: "First", choices: [], multiSelect: false),
                        ClarifyQuestion(id: "edited", question: "Second", choices: [], multiSelect: false),
                        ClarifyQuestion(id: "unchanged", question: "Third", choices: [], multiSelect: false)],
            lockedAnswers: ["edited": "before", "unchanged": "keep"])
        let model = BatchClarifyModel(request: request)
        model.setDraft("new", for: model.questions[0])
        model.setDraft("after", for: model.questions[1])
        var sent: [String] = []
        let completed = await model.confirm { qid, _ in sent.append(qid); return ClarifyRespondResult(status: "ok", remaining: nil) }
        XCTAssertTrue(completed)
        XCTAssertEqual(sent, ["edited", "missing"])
        XCTAssertEqual(model.lockedAnswers, ["edited": "after", "unchanged": "keep", "missing": "new"])
    }

    /// Editing is local. A batch card that sent each answer as it was given
    /// would fire the turn the moment the last field was touched, freezing
    /// earlier answers the user was still working on.
    func testAnswersStayEditableAndUnsentUntilConfirm() async throws {
        let (harness, _, request) = try await parkBatchClarify()
        let model = BatchClarifyModel(request: request)
        XCTAssertEqual(model.questions.count, 3, "the batch payload must decode into three questions")

        let target = try XCTUnwrap(model.questions.first)
        model.toggleChoice("staging (Recommended)", for: target)
        XCTAssertEqual(model.answer(for: target), "staging (Recommended)")

        // Change your mind twice. Both are local.
        model.toggleChoice("prod", for: target)
        XCTAssertEqual(model.answer(for: target), "prod")
        model.setDraft("somewhere else entirely", for: target)
        XCTAssertEqual(model.answer(for: target), "somewhere else entirely",
                       "typing replaces a picked choice rather than sitting beside it")

        let sent = await harness.backend.callCount("clarify.respond")
        XCTAssertEqual(sent, 0, "nothing may reach the backend before Confirm")
        XCTAssertFalse(model.canConfirm, "two of three questions are still unanswered")
        XCTAssertNil(model.outcome)

        await harness.tearDown()
    }

    /// Confirm sends exactly one `clarify.respond` per question, in order, each
    /// addressed by its qid. A multi-select answer goes as a JSON array, which
    /// the backend's `_parse_multi_select_response` tries before it falls back
    /// to splitting on commas.
    func testConfirmSendsOneAddressedAnswerPerQuestion() async throws {
        let (harness, chat, request) = try await parkBatchClarify()
        await harness.backend.stub("clarify.respond") { _ in
            .object(["status": .string("ok"), "remaining": .array([])])
        }
        let model = BatchClarifyModel(request: request)

        let questions = model.questions
        guard questions.count == 3 else {
            XCTFail("the batch payload must decode into three questions, got \(questions.count)")
            return await harness.tearDown()
        }
        model.toggleChoice("prod", for: questions[0])
        model.toggleChoice("us-east", for: questions[1])
        model.toggleChoice("eu-west", for: questions[1])
        model.setDraft("  it is a Friday  ", for: questions[2])
        XCTAssertTrue(model.canConfirm)

        let landed = await model.confirm { questionID, answer in
            await chat.lockClarifyAnswer(answer, questionID: questionID, requestID: request.id)
        }
        XCTAssertTrue(landed)
        XCTAssertEqual(model.outcome, .confirmed)

        let calls = await harness.backend.calls(to: "clarify.respond")
        XCTAssertEqual(calls.count, 3, "one lock per question, no more and no fewer")
        XCTAssertEqual(calls.map { $0.params["question_id"]?.coercedString }, ["q0", "q1", "q2"],
                       "an answer with no question_id falls past the per-question lock and is discarded")
        XCTAssertEqual(calls.map { $0.params["request_id"]?.coercedString }, ["clr-batch", "clr-batch", "clr-batch"])
        guard calls.count == 3 else { return await harness.tearDown() }
        XCTAssertEqual(calls[0].params["answer"]?.coercedString, "prod")
        XCTAssertEqual(calls[1].params["answer"]?.coercedString, #"["us-east","eu-west"]"#,
                       "a multi-select answer goes as a JSON array so a choice containing a comma survives")
        XCTAssertEqual(calls[2].params["answer"]?.coercedString, "it is a Friday",
                       "the typed answer is trimmed, not sent with its whitespace")

        // A second Confirm must not re-send: the batch is already resolved and
        // the turn has moved on.
        let again = await model.confirm { _, _ in ClarifyRespondResult(status: "ok", remaining: nil) }
        XCTAssertFalse(again)
        let afterSecond = await harness.backend.callCount("clarify.respond")
        XCTAssertEqual(afterSecond, 3)

        await harness.tearDown()
    }

    /// The deadline does not mean the answers were lost. The backend keeps
    /// every answer locked before it and tells the agent the rest are absences
    /// rather than skips — so the card settles on what was retained.
    func testExpireKeepsTheAnswersThatAlreadyLanded() async throws {
        let (harness, _, request) = try await parkBatchClarify(
            replayedAnswers: .object(["q0": .string("prod")])
        )
        let model = BatchClarifyModel(request: request)

        XCTAssertEqual(model.lockedAnswers, ["q0": "prod"],
                       "a reconnect replays the locks the backend already holds")
        let first = try XCTUnwrap(model.questions.first)
        XCTAssertTrue(model.isAnswered(first), "a replayed lock restores as an answered question")

        model.expire()
        XCTAssertEqual(model.outcome, .expired(retained: ["q0": "prod"]),
                       "expire must report what survived, not assume everything was discarded")

        // And once settled it stays settled — a late Confirm cannot re-open it.
        let late = await model.confirm { _, _ in ClarifyRespondResult(status: "ok", remaining: nil) }
        XCTAssertFalse(late)
        let sent = await harness.backend.callCount("clarify.respond")
        XCTAssertEqual(sent, 0)

        await harness.tearDown()
    }

    // MARK: - Helpers

    /// Park a three-question batch `clarify.request` on a live chat, through
    /// the real socket, the real `TurnEngine` and the real projection.
    private func parkBatchClarify(
        replayedAnswers: JSONValue? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (AppHarness, ChatModel, ClarifyRequestEvent) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260823_120000_batchclarify")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID, file: file, line: line)

        var payload: [String: JSONValue] = [
            "request_id": .string("clr-batch"),
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
                    "choices": .null,
                    "multi_select": .bool(false),
                ]),
            ]),
        ]
        if let replayedAnswers { payload["answers"] = replayedAnswers }

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object(payload))
        let parked = await waitUntil { chat.pendingClarify != nil }
        XCTAssertTrue(parked, "the batch clarify never parked", file: file, line: line)

        let request = try XCTUnwrap(chat.pendingClarify, file: file, line: line)
        XCTAssertTrue(request.isBatch, "a `questions` payload must project as a batch", file: file, line: line)
        return (harness, chat, request)
    }
}

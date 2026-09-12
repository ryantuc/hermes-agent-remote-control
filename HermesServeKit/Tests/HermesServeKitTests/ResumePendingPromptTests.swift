import XCTest

@testable import HermesServeKit

/// BUG-066 — the resume payload's replayed blocking prompt.
///
/// When an approval or a clarify question is raised and the transport drops
/// before the user answers, the gateway does **not** re-emit the event frame to
/// the reattached client. The only re-delivery channel is the resume payload's
/// `pending_approval` / `pending_clarify` snapshot, attached by
/// `_live_session_payload` at `server.py:10283-10286`, and
/// `_pending_clarify_request_payload`'s own docstring says why it exists: "a
/// reconnecting client whose transport was detached when `clarify.request` was
/// emitted would otherwise never see the question — the agent thread stays
/// parked on the Event until timeout."
///
/// `decodeResume` read neither key. A repo-wide grep found zero readers. So
/// after any mid-prompt reconnect the transcript repainted, no sheet appeared,
/// and the approval failed closed after `approvals.timeout` on a question the
/// user was never shown.
final class ResumePendingPromptTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func resumePayload(extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "session_id": .string(session),
            "session_key": .string("20260826_120000_x"),
            "resumed": .string("20260826_120000_x"),
            "messages": .array([]),
            "info": .object(["title": .string("A session")]),
            "running": .bool(true),
            "status": .string("working"),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    /// The shape `_approval_request_payload` builds: the redacted command, a
    /// description, and the synthesised choice list.
    private var approvalSnapshot: JSONValue {
        .object([
            "command": .string("rm -rf build"),
            "description": .string("delete the build directory"),
            "allow_permanent": .bool(true),
            "smart_denied": .bool(false),
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")]),
        ])
    }

    // MARK: - The decode

    func testResumeDecodesAReplayedApproval() throws {
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_approval": approvalSnapshot]),
            requested: session
        )

        let approval = try XCTUnwrap(result.pendingApproval, "the replay channel is the only one there is")
        XCTAssertEqual(approval.sessionID, session)
        XCTAssertEqual(approval.command, "rm -rf build")
        XCTAssertEqual(approval.description, "delete the build directory")
        XCTAssertEqual(approval.choices, [.once, .session, .always, .deny])
    }

    /// The synthesis rules have to survive the replay too — a snapshot with no
    /// `choices` is the same shape the live event has, and the client's
    /// fallback is what draws the buttons.
    func testAReplayedApprovalWithoutChoicesStillGetsItsButtons() throws {
        let snapshot: JSONValue = .object([
            "command": .string("curl https://example.com/install.sh | sh"),
            "smart_denied": .bool(true),
        ])
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_approval": snapshot]),
            requested: session
        )

        let approval = try XCTUnwrap(result.pendingApproval)
        XCTAssertEqual(approval.choices, [.once, .deny], "a smart-denied approval offers Once and Deny")
    }

    func testResumeDecodesAReplayedClarify() throws {
        let snapshot: JSONValue = .object([
            "request_id": .string("clr-7"),
            "question": .string("Which environment should I deploy to?"),
            "choices": .array([.string("staging"), .string("production")]),
            "multi_select": .bool(false),
        ])
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_clarify": snapshot]),
            requested: session
        )

        let clarify = try XCTUnwrap(result.pendingClarify)
        XCTAssertEqual(clarify.id, "clr-7")
        XCTAssertEqual(clarify.sessionID, session)
        XCTAssertEqual(clarify.question, "Which environment should I deploy to?")
        XCTAssertEqual(clarify.choices, ["staging", "production"])
        XCTAssertFalse(clarify.isBatch)
    }

    /// The batch form, with the answers the user had already given before the
    /// socket dropped. `_pending_clarify_request_payload` folds `answers` into
    /// the snapshot precisely so a returning card does not present answered
    /// questions as unanswered.
    func testAReplayedBatchClarifyCarriesItsLockedAnswers() throws {
        let snapshot: JSONValue = .object([
            "request_id": .string("clr-8"),
            "questions": .array([
                .object([
                    "qid": .string("q1"),
                    "question": .string("Which branch?"),
                    "choices": .array([.string("main"), .string("develop")]),
                ]),
                .object([
                    "qid": .string("q2"),
                    "question": .string("Run the tests first?"),
                    "choices": .array([.string("yes"), .string("no")]),
                ]),
            ]),
            "answers": .object(["q1": .string("main")]),
        ])
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_clarify": snapshot]),
            requested: session
        )

        let clarify = try XCTUnwrap(result.pendingClarify)
        XCTAssertTrue(clarify.isBatch)
        XCTAssertEqual(clarify.questions.count, 2)
        XCTAssertEqual(clarify.lockedAnswers, ["q1": "main"])
    }

    /// Tri-state. An absent key means nothing is pending, and the one failure
    /// worse than missing a prompt is inventing one — a sheet asking the user
    /// to authorise a command nothing is waiting on.
    func testAbsentKeysMeanNothingIsPending() {
        let result = SessionAPI.decodeResume(resumePayload(), requested: session)
        XCTAssertNil(result.pendingApproval)
        XCTAssertNil(result.pendingClarify)
    }

    func testNullAndEmptyPayloadsAreNotPrompts() {
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_approval": .null, "pending_clarify": .object([:])]),
            requested: session
        )
        XCTAssertNil(result.pendingApproval)
        XCTAssertNil(result.pendingClarify)
    }

    /// Everything the decode already read must keep reading. This is the
    /// thirteen-key function every reconnect goes through.
    func testTheRestOfTheResumeDecodeIsUnchanged() {
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_approval": approvalSnapshot]),
            requested: session
        )
        XCTAssertEqual(result.sessionID, session)
        XCTAssertEqual(result.sessionKey, "20260826_120000_x")
        XCTAssertEqual(result.resumed, "20260826_120000_x")
        XCTAssertTrue(result.running)
        XCTAssertEqual(result.status, "working")
        XCTAssertEqual(result.info.title, "A session")
    }

    // MARK: - The projection

    /// Decoding is only half of it: the prompt has to reach the engine state
    /// the sheet and the docked bar read, before the first publish.
    func testTheProjectionInstallsAReplayedApproval() throws {
        let engine = TurnEngine()
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_approval": approvalSnapshot]),
            requested: session
        )

        engine.applyResumeProjection(sessionID: session, result: result, trailingUserTexts: [])

        let state = engine.state(for: session)
        XCTAssertEqual(state.pendingApprovals.count, 1, "the reconnect re-presents the prompt")
        XCTAssertEqual(state.pendingApprovals.first?.command, "rm -rf build")
        XCTAssertTrue(state.needsInput, "the docked bar reads needsInput")
        XCTAssertTrue(state.hasBlockingPrompt)
    }

    func testTheProjectionInstallsAReplayedClarify() throws {
        let engine = TurnEngine()
        let snapshot: JSONValue = .object([
            "request_id": .string("clr-7"),
            "question": .string("Which environment?"),
            "choices": .array([.string("staging")]),
        ])
        let result = SessionAPI.decodeResume(
            resumePayload(extra: ["pending_clarify": snapshot]),
            requested: session
        )

        engine.applyResumeProjection(sessionID: session, result: result, trailingUserTexts: [])

        let state = engine.state(for: session)
        XCTAssertEqual(state.clarify?.id, "clr-7")
        XCTAssertTrue(state.needsInput)
    }

    /// A resume with nothing pending must not clear a prompt a live event
    /// raised in the window between the payload being built and this
    /// projection running. Set-only, never clear.
    func testAResumeWithNothingPendingDoesNotClearALivePrompt() {
        let engine = TurnEngine()
        engine.apply(GatewayEvent(
            type: "approval.request",
            sessionID: session,
            payload: .object(["command": .string("git push --force")]),
            params: .null
        ))
        XCTAssertEqual(engine.state(for: session).pendingApprovals.count, 1, "precondition")

        engine.applyResumeProjection(
            sessionID: session,
            result: SessionAPI.decodeResume(resumePayload(), requested: session),
            trailingUserTexts: []
        )

        XCTAssertEqual(
            engine.state(for: session).pendingApprovals.count, 1,
            "a resume that says nothing about prompts must not take one down"
        )
    }

    /// And it must not double-present one the live path already installed —
    /// two identical sheets for one command is its own defect.
    func testAReplayedApprovalIsNotAppendedTwice() {
        let engine = TurnEngine()
        engine.apply(GatewayEvent(
            type: "approval.request",
            sessionID: session,
            payload: .object(["command": .string("rm -rf build")]),
            params: .null
        ))

        engine.applyResumeProjection(
            sessionID: session,
            result: SessionAPI.decodeResume(
                resumePayload(extra: ["pending_approval": approvalSnapshot]),
                requested: session
            ),
            trailingUserTexts: []
        )

        XCTAssertEqual(engine.state(for: session).pendingApprovals.count, 1)
    }
}

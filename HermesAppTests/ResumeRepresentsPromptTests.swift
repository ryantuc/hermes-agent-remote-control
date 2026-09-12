import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// Resume payloads, free-standing for the same reason `BotChatResolverTests`
/// keeps its `Wire` enum outside the class: `ScriptedBackend.stub` takes a
/// `@Sendable` closure that runs off the main actor, and a helper on a
/// `@MainActor` test class cannot be called from inside one.
private enum ResumeWire {
    static func payload(runtime: String, key: String, extra: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "session_id": .string(runtime),
            "session_key": .string(key),
            "resumed": .string(key),
            "messages": .array([]),
            "info": ScriptedBackend.info(title: "Scripted thread"),
            "running": .bool(true),
            "status": .string("working"),
        ]
        for (name, value) in extra { object[name] = value }
        return .object(object)
    }

    static let approvalSnapshot: JSONValue = .object([
        "command": .string("rm -rf build"),
        "description": .string("delete the build directory"),
        "choices": .array([
            .string("once"), .string("session"), .string("always"), .string("deny"),
        ]),
    ])

    static let clarifySnapshot: JSONValue = .object([
        "request_id": .string("clr-9"),
        "question": .string("Which environment should I deploy to?"),
        "choices": .array([.string("staging"), .string("production")]),
    ])
}

/// BUG-066, from the surface the user actually looks at.
///
/// The kit tests pin the decode and the engine projection. This pins the claim
/// those exist to make: after a reconnect into a session the gateway is still
/// blocked on, the chat re-presents the prompt. The gateway does not re-emit
/// the event frame to a reattached transport, so if this does not happen the
/// user sees a repainted transcript, no sheet, and an approval that fails
/// closed on a question they were never asked.
@MainActor
final class ResumeRepresentsPromptTests: XCTestCase {

    func testAResumeCarryingAPendingApprovalRePresentsTheSheet() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260826_120000_resume_approval"
        await harness.backend.stub("session.resume") { _ in
            ResumeWire.payload(
                runtime: "rt-resume-approval",
                key: storedID,
                extra: ["pending_approval": ResumeWire.approvalSnapshot]
            )
        }

        let chat = harness.chat(storedID: storedID)
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")

        let approval = try XCTUnwrap(
            chat.pendingApproval,
            "the reconnect repainted the transcript and dropped the prompt the agent is parked on"
        )
        XCTAssertEqual(approval.command, "rm -rf build")

        let prompt = try XCTUnwrap(chat.presentedBlockingPrompt(minimised: false))
        guard case .approval = prompt else {
            return XCTFail("the sheet must come back as an approval, not \(prompt)")
        }
        XCTAssertTrue(chat.hasBlockingPrompt)

        await harness.tearDown()
    }

    func testAResumeCarryingAPendingClarifyRePresentsTheQuestion() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260826_120000_resume_clarify"
        await harness.backend.stub("session.resume") { _ in
            ResumeWire.payload(
                runtime: "rt-resume-clarify",
                key: storedID,
                extra: ["pending_clarify": ResumeWire.clarifySnapshot]
            )
        }

        let chat = harness.chat(storedID: storedID)
        await chat.open()
        _ = await waitUntil { chat.runtimeSessionID != nil }

        let clarify = try XCTUnwrap(chat.pendingClarify, "the clarify question never came back")
        XCTAssertEqual(clarify.id, "clr-9")
        XCTAssertEqual(clarify.question, "Which environment should I deploy to?")

        await harness.tearDown()
    }

    /// The other half of the tri-state: a resume that says nothing is pending
    /// leaves the surface alone. Inventing a prompt is the worse failure.
    func testAnOrdinaryResumeRaisesNoPrompt() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()

        let storedID = "20260826_120000_resume_quiet"
        await harness.backend.stub("session.resume") { _ in
            ResumeWire.payload(runtime: "rt-resume-quiet", key: storedID, extra: [:])
        }

        let chat = harness.chat(storedID: storedID)
        await chat.open()
        _ = await waitUntil { chat.runtimeSessionID != nil }

        XCTAssertNil(chat.pendingApproval)
        XCTAssertNil(chat.pendingClarify)
        XCTAssertFalse(chat.hasBlockingPrompt)
        XCTAssertNil(chat.presentedBlockingPrompt(minimised: false))

        await harness.tearDown()
    }
}

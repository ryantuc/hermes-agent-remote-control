import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A command the client refuses before it reaches the backend must leave Home where it is. Home promotes its draft into a conversation the moment `hasStartedSubmission` rises, and a refusal that rose it first opened an empty new chat, created a session for it, and lost the refusal line to that chat's own open (sending "/model" from Home showed Home's empty state inside a new conversation, with "/model" still in the composer).
@MainActor
final class HomeRefusedCommandLandingTests: XCTestCase {

    private func type(_ text: String, into chat: ChatModel) {
        chat.draft = text
        chat.slashCompletion.update(
            text: text, selection: NSRange(location: text.utf16.count, length: 0),
            isComposing: false, isPaste: false, isExternal: false,
            scope: chat.slashCompletionScope, api: chat.slashCommandAPI
        )
    }

    /// Home's draft: no stored session, no runtime session.
    private func homeDraft() async throws -> (AppHarness, ChatModel) {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = ChatModel(app: harness.app, summary: nil)
        XCTAssertTrue(chat.isDraft)
        return (harness, chat)
    }

    private func assertRefusedOnHome(_ draft: String, reason: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (harness, chat) = try await homeDraft()
        type(draft, into: chat)
        XCTAssertTrue(chat.slashCompletion.commandIntent(for: draft), "precondition: a typed command", file: file, line: line)

        chat.sendTapped()

        XCTAssertFalse(chat.hasStartedSubmission, "\(draft): a refusal raised the signal Home leaves for a new conversation on", file: file, line: line)
        XCTAssertEqual(chat.errorMessage, reason, "\(draft): the refusal must be on the draft in the tap frame, where Home can show it", file: file, line: line)
        XCTAssertEqual(chat.draft, draft, file: file, line: line)
        // Nothing reaches the backend afterwards either.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let creates = await harness.backend.callCount("session.create")
        XCTAssertEqual(creates, 0, "\(draft): a refused command created a backend session", file: file, line: line)
        XCTAssertTrue(chat.isDraft, file: file, line: line)
        XCTAssertEqual(chat.errorMessage, reason, "\(draft): the refusal did not survive", file: file, line: line)
        await harness.tearDown()
    }

    func testModelRefusalStaysOnHome() async throws {
        try await assertRefusedOnHome("/model", reason: "/model is not available in HARC. The draft has been kept.")
    }

    func testEveryLocallyUnavailableCommandStaysOnHome() async throws {
        for name in ["/new", "/reset", "/resume", "/compress", "/voice"] {
            try await assertRefusedOnHome(name, reason: "\(name) is not available in HARC. The draft has been kept.")
        }
    }

    func testAnUnavailableCommandWithArgumentsStaysOnHome() async throws {
        try await assertRefusedOnHome("/title Weekly notes", reason: "/title is not available in HARC. The draft has been kept.")
    }

    func testMisusedLocalCommandsStayOnHome() async throws {
        try await assertRefusedOnHome("/stop now", reason: "Use /stop without arguments.")
        try await assertRefusedOnHome("/btw", reason: "Use /btw followed by your question.")
    }

    /// The same refusal inside a conversation lands on its error row, in the tap frame, and starts nothing.
    func testTheRefusalInAChatLandsOnItsErrorRowAndRunsNothing() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261009_refusal")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound)
        type("/new", into: chat)
        chat.sendTapped()
        XCTAssertEqual(chat.errorMessage, "/new is not available in HARC. The draft has been kept.")
        XCTAssertEqual(chat.draft, "/new")
        let ran = await harness.backend.callCount("slash.exec")
        XCTAssertEqual(ran, 0)
        await harness.tearDown()
    }

    /// A command HARC can run from Home still promotes on the tap.
    func testASupportedCommandStillLeavesHomeOnTheTap() async throws {
        let (harness, chat) = try await homeDraft()
        await harness.backend.gate("session.create")
        type("/usage", into: chat)
        chat.sendTapped()
        XCTAssertTrue(chat.hasStartedSubmission)
        XCTAssertNil(chat.errorMessage)
        await harness.backend.ungate("session.create")
        await harness.backend.releaseParked()
        _ = await waitUntil { !chat.isExecutingSlash }
        await harness.tearDown()
    }
}

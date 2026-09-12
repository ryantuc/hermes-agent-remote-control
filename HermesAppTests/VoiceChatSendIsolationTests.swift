import Foundation
import XCTest

@testable import HermesMobile

/// BUG-127: voice turns have a payload independent from the visible composer.
final class VoiceChatSendIsolationTests: XCTestCase {
    @MainActor
    func testVoiceTurnPreservesDraftAndStagedAttachment() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260831_100001_voice-isolation")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")

        let staged = PendingAttachment(filename: "photo.png", mimeType: "image/png", data: Data([1]), kind: .image)
        chat.draft = "typed but not sent"
        chat.attachments = [staged]
        await harness.backend.gate("prompt.submit")

        XCTAssertTrue(chat.sendVoiceTurn("spoken separately"), "a connected voice turn must be accepted")
        XCTAssertEqual(chat.draft, "typed but not sent", "voice must not clear the typed composer draft")
        XCTAssertEqual(chat.attachments, [staged], "voice must not consume a staged attachment")
        XCTAssertEqual(chat.outbound.last?.text, "spoken separately")
        XCTAssertEqual(chat.outbound.last?.attachments, [], "voice sends no hidden attachments")

        await harness.backend.ungate("prompt.submit")
        await harness.backend.releaseParked()
        await harness.tearDown()
    }

    @MainActor
    func testDisconnectedVoiceTurnLeavesComposerUntouched() async {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20260831_100002_voice-disconnected")
        let staged = PendingAttachment(filename: "photo.png", mimeType: "image/png", data: Data([1]), kind: .image)
        chat.draft = "typed but not sent"
        chat.attachments = [staged]

        XCTAssertFalse(chat.sendVoiceTurn("spoken separately"))
        XCTAssertEqual(chat.draft, "typed but not sent")
        XCTAssertEqual(chat.attachments, [staged])
        XCTAssertTrue(chat.outbound.isEmpty, "a disconnected voice turn must not create an optimistic message")

        await harness.tearDown()
    }
}

import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-031 — after clarify/sudo/secret expire, the sheet item must be nil.
/// ChatView used to keep a sticky `@State activePrompt` and only dismiss on
/// `onChange(of: promptIdentity)`, which can miss the expire. The sheet now
/// binds to `ChatModel.presentedBlockingPrompt(minimised:)`.
@MainActor
final class ChatModelExpiredPromptSheetTests: XCTestCase {

    func testClarifyExpireClearsPresentedPrompt() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20260818_031000_expire")
        await chat.open()
        let runtimeID = try XCTUnwrap(chat.runtimeSessionID)

        await harness.backend.emit("message.start", sessionID: runtimeID)
        await harness.backend.emit("clarify.request", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-exp"),
            "question": .string("Still there?"),
        ]))
        let parked = await waitUntil { chat.currentBlockingPrompt != nil }
        XCTAssertTrue(parked, "the clarify never parked")
        XCTAssertNotNil(chat.presentedBlockingPrompt(minimised: false))
        XCTAssertNil(chat.presentedBlockingPrompt(minimised: true))

        await harness.backend.emit("clarify.expire", sessionID: runtimeID, payload: .object([
            "request_id": .string("q-exp"),
        ]))
        let gone = await waitUntil { chat.currentBlockingPrompt == nil }
        XCTAssertTrue(gone, "expire did not clear engine state")
        XCTAssertNil(
            chat.presentedBlockingPrompt(minimised: false),
            "the sheet item must die with the prompt — a sticky @State would leave a zombie"
        )

        await harness.tearDown()
    }
}

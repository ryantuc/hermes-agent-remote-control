import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// A rename, pin, archive or delete the backend refuses must leave the list as the backend has it and say why. The harness's REST host refuses every connection, so every write here fails, and so does the refresh that follows it.
final class SessionEditRefusalTests: XCTestCase {

    @MainActor
    func testARefusedDeleteBringsTheRowBackWhereItWasEvenWhenTheListCannotBeReread() async throws {
        let harness = await AppHarness.make()
        harness.app.seedDemoThreads()
        let before = harness.app.threads.map(\.id)
        let target = try XCTUnwrap(harness.app.threads.first { $0.id == "d3" })

        await harness.app.deleteThread(target)

        XCTAssertEqual(harness.app.threads.map(\.id), before, "the backend still has the conversation, so the list must too, in the same place")
        XCTAssertEqual(harness.app.sessionEditNotice?.action, .delete)
        await harness.tearDown()
    }

    @MainActor
    func testEveryRefusedEditLeavesANoticeNamingWhatDidNotHappen() async throws {
        let harness = await AppHarness.make()
        harness.app.seedDemoThreads()
        let pinned = try XCTUnwrap(harness.app.threads.first { $0.id == "d1" })
        let plain = try XCTUnwrap(harness.app.threads.first { $0.id == "d3" })
        let archived = try XCTUnwrap(harness.app.threads.first { $0.id == "d7" })
        XCTAssertNil(harness.app.sessionEditNotice)

        await harness.app.setPinned(plain, pinned: true)
        XCTAssertEqual(harness.app.sessionEditNotice?.action, .pin)
        XCTAssertEqual(harness.app.sessionEditNotice?.title, "Couldn't pin this conversation")

        await harness.app.setPinned(pinned, pinned: false)
        XCTAssertEqual(harness.app.sessionEditNotice?.action, .unpin)

        await harness.app.setArchived(plain, archived: true)
        XCTAssertEqual(harness.app.sessionEditNotice?.action, .archive)

        await harness.app.setArchived(archived, archived: false)
        XCTAssertEqual(harness.app.sessionEditNotice?.action, .unarchive)

        await harness.app.renameThread(plain, to: "A new name")
        XCTAssertEqual(harness.app.sessionEditNotice?.action, .rename)
        XCTAssertEqual(harness.app.sessionEditNotice?.message, "The backend couldn't be reached. Check the connection and try again.")
        XCTAssertEqual(harness.app.threads.first { $0.id == "d3" }?.title, plain.title, "a refused rename keeps the title the backend has")
        await harness.tearDown()
    }

    // MARK: What the notice says

    func testAPhoneStartedConversationRefusedAsNotFoundSaysSoInPlainWords() {
        let notice = SessionEditNotice(action: .archive, error: HermesError.httpStatus(code: 404, message: "not_found"), source: "ios")
        XCTAssertEqual(notice.title, "Couldn't archive this conversation")
        XCTAssertEqual(notice.message, "This version of Hermes doesn't let the phone change conversations that were started on the phone. Nothing was changed.")
    }

    func testTheSameRefusalOnAnotherConversationDoesNotBlameThePhone() {
        let message = SessionEditNotice.reason(for: HermesError.httpStatus(code: 404, message: "not_found"), source: "desktop")
        XCTAssertEqual(message, "The backend wouldn't change this conversation. Nothing was changed.")
        XCTAssertFalse(message.contains("phone"))
    }

    func testEachRefusalHasItsOwnSentence() {
        func reason(_ code: Int, _ detail: String) -> String {
            SessionEditNotice.reason(for: HermesError.httpStatus(code: code, message: detail), source: "cli")
        }
        XCTAssertEqual(reason(404, "Session not found"), "This conversation is no longer on the backend.")
        XCTAssertEqual(reason(409, "revision_conflict"), "This conversation changed somewhere else just now. Try again.")
        XCTAssertEqual(reason(409, "stale_generation"), "This conversation changed somewhere else just now. Try again.")
        XCTAssertEqual(reason(409, "session_busy"), "This conversation is busy right now. Try again when it has finished.")
        XCTAssertEqual(reason(403, "permission_denied"), "The backend doesn't allow the phone to change this conversation. Nothing was changed.")
        XCTAssertEqual(reason(500, "Internal server error"), "HTTP 500: Internal server error", "anything else is the backend's own sentence")
        XCTAssertEqual(
            SessionEditNotice.reason(for: HermesError.connectFailed("Could not connect to the server."), source: "ios"),
            "The backend couldn't be reached. Check the connection and try again.",
            "a phone that never reached the backend is not told the backend refused it"
        )
    }

    func testEachActionNamesItself() {
        let error = HermesError.httpStatus(code: 409, message: "revision_conflict")
        let titles: [SessionEditNotice.Action: String] = [
            .rename: "Couldn't rename this conversation",
            .pin: "Couldn't pin this conversation",
            .unpin: "Couldn't unpin this conversation",
            .archive: "Couldn't archive this conversation",
            .unarchive: "Couldn't unarchive this conversation",
            .delete: "Couldn't delete this conversation",
        ]
        for (action, title) in titles {
            XCTAssertEqual(SessionEditNotice(action: action, error: error, source: "").title, title)
        }
    }
}

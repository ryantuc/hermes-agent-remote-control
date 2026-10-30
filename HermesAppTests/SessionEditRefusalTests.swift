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
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.action, .delete)
        await harness.tearDown()
    }

    @MainActor
    func testEveryRefusedEditLeavesANoticeNamingWhatDidNotHappen() async throws {
        let harness = await AppHarness.make()
        harness.app.seedDemoThreads()
        let pinned = try XCTUnwrap(harness.app.threads.first { $0.id == "d1" })
        let plain = try XCTUnwrap(harness.app.threads.first { $0.id == "d3" })
        let archived = try XCTUnwrap(harness.app.threads.first { $0.id == "d7" })
        XCTAssertNil(harness.app.sessionEditNotices.front)

        await harness.app.setPinned(plain, pinned: true)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.action, .pin)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.title, "Couldn't pin “Landscape audit”", "the notice can land over another conversation, so it names the one it is about")

        await harness.app.setPinned(pinned, pinned: false)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.action, .unpin)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.title, "Couldn't unpin “Composer pill measurements”")

        await harness.app.setArchived(plain, archived: true)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.action, .archive)

        await harness.app.setArchived(archived, archived: false)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.action, .unarchive)

        await harness.app.renameThread(plain, to: "A new name")
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.action, .rename)
        XCTAssertEqual(harness.app.sessionEditNotices.latest?.message, "The backend couldn't be reached. Check the connection and try again.")
        XCTAssertEqual(harness.app.threads.first { $0.id == "d3" }?.title, plain.title, "a refused rename keeps the title the backend has")

        XCTAssertEqual(harness.app.sessionEditNotices.pending.map(\.action), [.archive, .unarchive, .rename], "five refusals with nobody dismissing: the newest three wait, oldest first")
        await harness.tearDown()
    }

    // MARK: Two refusals close together

    func testDismissingTheShownNoticeHandsOverToTheOneBehindIt() {
        var queue = SessionEditNoticeQueue()
        let first = Self.notice(.pin, title: "A")
        let second = Self.notice(.archive, title: "B")
        queue.post(first)
        queue.post(second)
        XCTAssertEqual(queue.front, first)

        queue.dismiss(first.id)

        XCTAssertEqual(queue.front, second, "a refusal that arrived while another was on screen must still be shown")
        queue.dismiss(first.id)
        XCTAssertEqual(queue.front, second, "dismissing the same notice twice must not take the next one with it")
        queue.dismiss(second.id)
        XCTAssertNil(queue.front)
    }

    func testABurstKeepsOnlyTheNewestFew() {
        var queue = SessionEditNoticeQueue()
        let notices = (0..<5).map { Self.notice(.pin, title: "Chat \($0)") }
        notices.forEach { queue.post($0) }
        XCTAssertEqual(queue.pending, Array(notices.suffix(SessionEditNoticeQueue.limit)))
        XCTAssertEqual(queue.latest, notices.last)
    }

    // MARK: What the notice says

    private static func conversation(title: String? = nil, preview: String = "", source: String = "cli") -> SessionSummary {
        var fields: [String: JSONValue] = ["id": .string("s1"), "preview": .string(preview), "source": .string(source)]
        if let title { fields["title"] = .string(title) }
        return SessionSummary(json: .object(fields))
    }

    private static func notice(_ action: SessionEditNotice.Action, title: String) -> SessionEditNotice {
        SessionEditNotice(action: action, error: HermesError.httpStatus(code: 409, message: "revision_conflict"), conversation: conversation(title: title))
    }

    func testAPhoneStartedConversationRefusedAsNotFoundSaysSoInPlainWords() {
        let notice = SessionEditNotice(
            action: .archive,
            error: HermesError.httpStatus(code: 404, message: "not_found"),
            conversation: Self.conversation(title: "Groceries", source: "ios")
        )
        XCTAssertEqual(notice.title, "Couldn't archive “Groceries”")
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

    /// 0.22.1 with a running gateway refuses every edit with `Gateway runtime already owns profile <home folder>` (`gateway/runtime_ownership.py:165` at that tag), and the folder is no business of the alert.
    func testTheGatewayOwnershipRefusalIsAPlainSentenceWithoutTheBackendsFolder() {
        let message = SessionEditNotice.reason(
            for: HermesError.httpStatus(code: 409, message: "Gateway runtime already owns profile /home/me/.hermes"),
            source: "desktop"
        )
        XCTAssertEqual(message, "Hermes's gateway is holding this conversation, so the phone can't change it right now.")
        XCTAssertFalse(message.contains("/home"))
    }

    func testEachActionNamesItselfAndTheConversation() {
        let error = HermesError.httpStatus(code: 409, message: "revision_conflict")
        let verbs: [SessionEditNotice.Action: String] = [
            .rename: "rename", .pin: "pin", .unpin: "unpin", .archive: "archive", .unarchive: "unarchive", .delete: "delete",
        ]
        for (action, verb) in verbs {
            XCTAssertEqual(SessionEditNotice(action: action, error: error, conversation: Self.conversation(title: "Groceries")).title, "Couldn't \(verb) “Groceries”")
        }
        XCTAssertEqual(
            SessionEditNotice(action: .pin, error: error, conversation: Self.conversation(preview: "Plan the trip")).title,
            "Couldn't pin “Plan the trip”",
            "an untitled row is named the way the hub names it"
        )
        XCTAssertEqual(
            SessionEditNotice(action: .delete, error: error, conversation: Self.conversation()).title,
            "Couldn't delete this conversation",
            "a row with nothing to call it falls back to plain words"
        )
    }
}

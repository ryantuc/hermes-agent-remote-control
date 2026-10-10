import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// After the backend refuses a Retry or Edit & resend with 4018 ("target user message is no longer in session history"), the chat looks the replaced turn up once more by its text. The backend has just said the old row is gone, so a lone match may be a different message that reads the same (a second "continue"), and cutting there deletes turns the person never agreed to lose. The re-found row is accepted only where the person saw the replaced turn: the same number of user turns in all, and the same number after it.
@MainActor
final class ReplacementRefindTests: XCTestCase {
    private func row(_ id: Int, _ role: String, _ content: String) -> TranscriptMessage {
        TranscriptMessage(json: .object([
            "id": .number(Double(id)), "role": .string(role), "content": .string(content), "timestamp": .number(1_790_000_000),
        ]))
    }

    private func replacement(rowID: Int, text: String, after: Int, total: Int, latest: Bool = false) -> ChatModel.OutboundMessage.Replacement {
        ChatModel.OutboundMessage.Replacement(entryID: "rest-\(rowID)", rowID: rowID, text: text, isLatestUserTurn: latest,
                                              userTurnsAfter: after, userTurnCount: total)
    }

    /// The case: "continue" (row 10) and a later "continue" (row 20); the person retries the first, which was deleted on another client. The only match left is the later message, and cutting there deletes it and its answer.
    func testALaterMessageWithTheSameTextIsNotTakenForTheGoneOne() {
        let rows = [row(20, "user", "continue"), row(21, "assistant", "second answer")]
        let gone = replacement(rowID: 10, text: "continue", after: 1, total: 2)
        XCTAssertNil(ChatModel.refoundRowID(for: gone, in: rows),
                     "the re-lookup took row 20, a different message that reads the same, and a cut there deletes it and its answer")
    }

    /// The same mistake the other way: an earlier "continue" (row 5) remains after the replaced one (row 10) was deleted, and it even has the same number of user turns after it. Cutting there deletes a message from before the one the person chose.
    func testAnEarlierMessageWithTheSameTextIsNotTakenForTheGoneOne() {
        let rows = [
            row(5, "user", "continue"), row(6, "assistant", "first answer"),
            row(20, "user", "and then?"), row(21, "assistant", "third answer"),
        ]
        let gone = replacement(rowID: 10, text: "continue", after: 1, total: 3)
        XCTAssertNil(ChatModel.refoundRowID(for: gone, in: rows),
                     "the re-lookup took row 5, which sits before the replaced turn, and a cut there deletes more than the person agreed to")
    }

    /// The control: the replaced turn is still there under a new row (an earlier rewind rewrote the survivors' rows), at the same place with the same turns around it, so it is found and replaced.
    func testTheSameTurnUnderANewRowIsStillFound() {
        let rows = [
            row(15, "user", "continue"), row(16, "assistant", "first answer"),
            row(25, "user", "and then?"), row(26, "assistant", "second answer"),
        ]
        let moved = replacement(rowID: 10, text: "continue", after: 1, total: 2)
        XCTAssertEqual(ChatModel.refoundRowID(for: moved, in: rows), 15)
    }

    /// The control: the latest turn, re-stamped, with an identical earlier message: the latest-turn rule still finds it.
    func testTheLatestTurnUnderANewRowIsStillFound() {
        let rows = [
            row(15, "user", "continue"), row(16, "assistant", "first answer"),
            row(25, "user", "continue"), row(26, "assistant", "second answer"),
        ]
        let latest = replacement(rowID: 20, text: "continue", after: 0, total: 2, latest: true)
        XCTAssertEqual(ChatModel.refoundRowID(for: latest, in: rows), 25)
    }
}

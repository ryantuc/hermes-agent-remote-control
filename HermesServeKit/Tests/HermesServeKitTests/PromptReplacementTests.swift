import XCTest

@testable import HermesServeKit

/// Retry and Edit & resend replace a turn. `prompt.submit` cuts the stored history before a durable row when told to (`PromptSubmitParams.truncate_before_row_id`, `tui_gateway/contracts/prompt_voice.py:27-55`, declared on current and older backends), but only with explicit consent: without `confirm_truncate` it answers 4029 (`tui_gateway/methods_prompt.py:244-276`), and a cut that would leave nothing needs `confirm_empty_truncate` too (`:369-378`). Desktop sends both with every durable-row rewind (`apps/desktop/src/app/session/hooks/use-prompt-actions/rewind.ts:338-360`). The ack names the row it wrote (`user_row_id`, `prompt_voice.py:64-75`, live only; `methods_prompt.py:720-721`).
final class PromptReplacementTests: XCTestCase {
    private let session = "a1b2c3d4"

    func testAReplacementCarriesTheRowAndBothConsents() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "prompt.submit": [.object(["status": .string("streaming"), "survivor_user_row_ids": .array([.number(3)])])],
        ])

        _ = try await PromptAPI(client: client).submit(sessionID: session, text: "try again", replacingRowID: 41)

        let sent = await socket.sentParams("prompt.submit")
        let params = try XCTUnwrap(sent)
        XCTAssertEqual(params["truncate_before_row_id"]?.intValue, 41)
        XCTAssertEqual(params["confirm_truncate"]?.boolValue, true, "without consent the backend refuses the cut with 4029")
        XCTAssertEqual(params["confirm_empty_truncate"]?.boolValue, true,
                       "replacing the first turn leaves an empty prefix, which needs its own consent (4028)")
        XCTAssertNil(params["truncate_before_user_ordinal"], "a tail-relative ordinal would trip the 4030 cross-check")
        XCTAssertEqual(params["text"]?.stringValue, "try again")

        await client.disconnect()
    }

    /// The other half of the consent rule: a leftover truncation key on an ordinary send is how history was lost upstream (#80763).
    func testAnOrdinarySubmitCarriesNoTruncationKeys() async throws {
        let (client, socket) = try await ScriptedGateway.connected()

        _ = try await PromptAPI(client: client).submit(sessionID: session, text: "hello")

        let sent = await socket.sentParams("prompt.submit")
        let params = try XCTUnwrap(sent)
        for key in ["truncate_before_row_id", "truncate_before_user_ordinal", "truncate_before_message_id",
                    "confirm_truncate", "confirm_empty_truncate", "rebind_survivor_row_ids"] {
            XCTAssertNil(params[key], key)
        }

        await client.disconnect()
    }

    func testTheAckNamesTheRowItWrote() {
        XCTAssertEqual(PromptAck(json: .object(["status": .string("streaming"), "user_row_id": .number(77)])).userRowID, 77)
        XCTAssertNil(PromptAck(json: .object(["status": .string("streaming")])).userRowID, "an older backend sends no user_row_id")
        XCTAssertNil(PromptAck(json: .object(["status": .string("queued")])).userRowID)
    }

    // MARK: The engine's half

    func testTheAckedRowIsStampedOnTheUserEntry() {
        let engine = TurnEngine()
        let entryID = engine.appendUserEntry(sessionID: session, text: "hello")

        engine.setRowID(sessionID: session, entryID: entryID, rowID: 77)

        XCTAssertEqual(engine.state(for: session).entries.first?.rowID, 77)
    }

    func testDroppingSupersededEntriesKeepsTheReplacementAndWhatFollows() {
        let engine = TurnEngine()
        engine.appendNotice(sessionID: session, text: "earlier", kind: "background")
        let old = engine.appendUserEntry(sessionID: session, text: "first try")
        engine.appendNotice(sessionID: session, text: "the old reply", kind: "error")
        let replacement = engine.appendUserEntry(sessionID: session, text: "first try")
        engine.appendNotice(sessionID: session, text: "the new reply", kind: "background")

        engine.dropEntries(sessionID: session, from: old, before: replacement)

        XCTAssertEqual(engine.state(for: session).entries.map(\.text), ["earlier", "first try", "the new reply"])
        XCTAssertEqual(engine.state(for: session).entries[1].id, replacement)
    }

    /// A target that lives in the REST history above the live list: every live row before the replacement goes.
    func testDroppingFromTheStartOfTheLiveList() {
        let engine = TurnEngine()
        engine.appendNotice(sessionID: session, text: "old live row", kind: "background")
        let replacement = engine.appendUserEntry(sessionID: session, text: "again")

        engine.dropEntries(sessionID: session, from: nil, before: replacement)

        XCTAssertEqual(engine.state(for: session).entries.map(\.id), [replacement])
    }

    func testDroppingIsANoOpWhenTheReplacementIsGone() {
        let engine = TurnEngine()
        let old = engine.appendUserEntry(sessionID: session, text: "first try")

        engine.dropEntries(sessionID: session, from: old, before: "\(session)#user999")

        XCTAssertEqual(engine.state(for: session).entries.map(\.id), [old], "nothing may go when the replacement is not on screen")
    }

    /// Old encoded checkpoints have no `rowID`; they must still decode.
    func testAnEntryEncodedBeforeRowIDsStillDecodes() throws {
        let legacy = #"{"id":"rest-1","kind":"user","text":"hi","reasoning":"","isStreaming":false,"isInterim":false,"status":"","errorText":"","isPartial":false,"imageRefs":[],"noticeKind":"","timestamp":0}"#
        let entry = try JSONDecoder().decode(ChatEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.rowID)
        let stamped = ChatEntry(id: "rest-2", kind: .user, text: "x", rowID: 2)
        let roundTrip = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(stamped))
        XCTAssertEqual(roundTrip.rowID, 2)
    }
}

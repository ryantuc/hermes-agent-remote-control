import Foundation
import XCTest

@testable import HermesMobile
@testable import HermesServeKit

/// **BUG-123 / BUG-125 — the transcript projection, and what it costs to run it where it used to run.**
///
/// `ChatModel.open` used to project a fetched page on the main actor, between the spinner going up and the first row being laid out. The projection is not expensive arithmetic; it is expensive because `DisplayRedaction.toolOutput` runs `HermesServeKit.Redaction`'s whole pattern list over every tool result, and that list went from four regular expressions to twelve in the 27 August integration. These tests pin the two things that matter about moving it off the main actor: that it produces exactly what it produced before, and what the number actually is.
@MainActor
final class TranscriptProjectionOffMainTests: XCTestCase {

    /// The only property the move has to have. Same page in, same entries and same ordinals out — the hop changes the thread and nothing else.
    func testTheOffMainProjectionInstallsExactlyWhatTheMainOneDoes() async throws {
        let harness = await AppHarness.make()
        defer { Task { await harness.tearDown() } }

        let page = ChatModel.toolHeavyTranscriptPage(turns: 60)

        let onMain = harness.chat(storedID: "projection-parity-main")
        onMain.applyTranscript(page)

        let offMain = harness.chat(storedID: "projection-parity-offmain")
        await offMain.applyTranscriptProjectingOffMain(page)

        XCTAssertFalse(onMain.entries.isEmpty, "the fixture must produce rows or this test proves nothing")
        XCTAssertEqual(
            offMain.entries.map(\.id),
            onMain.entries.map(\.id),
            "the off-main projection produced a different set of rows"
        )
        XCTAssertEqual(
            offMain.entries.map(\.text),
            onMain.entries.map(\.text),
            "the off-main projection produced different text — redaction is part of the projection and must not be skipped"
        )
        XCTAssertEqual(
            offMain.entries.compactMap { $0.tool?.resultText },
            onMain.entries.compactMap { $0.tool?.resultText },
            "tool results differ, which is where the redaction cost lives"
        )
        XCTAssertEqual(
            offMain.historyOrdinals,
            onMain.historyOrdinals,
            "branch ordinals differ, which would make Branch from here copy the wrong amount"
        )
    }

    /// An empty page still never takes a transcript away on the off-main path — BUG-052's rule, re-asked on the far side of the hop.
    func testAnEmptyPageStillNeverBlanksATranscriptOnTheOffMainPath() async throws {
        let harness = await AppHarness.make()
        defer { Task { await harness.tearDown() } }

        let chat = harness.chat(storedID: "projection-empty-page")
        chat.applyTranscript(ChatModel.toolHeavyTranscriptPage(turns: 12))
        let before = chat.entries.map(\.id)
        XCTAssertFalse(before.isEmpty)

        await chat.applyTranscriptProjectingOffMain(TranscriptPage(sessionID: "", messages: []))

        XCTAssertEqual(chat.entries.map(\.id), before, "an empty page blanked a transcript that had rows")
    }

    /// Not a pass/fail claim about a number — a recorded one. The ceiling is deliberately far above anything a healthy machine produces, because a timing assertion tight enough to be interesting is a flake; the value of this test is the figure in its message and the fact that a tenfold regression would trip it.
    func testTheProjectionOfAToolHeavyPageIsRecorded() throws {
        let page = ChatModel.toolHeavyTranscriptPage()
        let started = ContinuousClock.now
        let projected = ChatModel.projectTranscriptWithOrdinals(page)
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15

        XCTAssertFalse(projected.entries.isEmpty)
        print("[cost] projectTranscriptWithOrdinals: \(page.messages.count) rows -> \(projected.entries.count) entries in \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(
            ms,
            10_000,
            "projectTranscriptWithOrdinals took \(ms) ms for \(page.messages.count) rows"
        )
    }
}

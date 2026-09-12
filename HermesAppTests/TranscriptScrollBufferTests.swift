import Foundation
import XCTest

@testable import HermesMobile

/// **FEAT-034 — the ring buffer behind Diagnostics' transcript scroll log.**
///
/// `TranscriptScrollLog` has written BUG-050's evidence to the unified log for some time, and the only reader it offered was `log stream` on a tethered Mac. That is not a step a person reporting the bug can be asked to perform, and BUG-050 has no other route to a terminal state, so the evidence has to be collectable inside the app.
///
/// The buffer is the whole of the mechanism and it is testable without a simulator, a socket or a transcript — which is the point of it being a type rather than a few lines inside the view.
final class TranscriptScrollBufferTests: XCTestCase {

    // MARK: 1 — append

    func testAppendKeepsWhatWasAppendedInTheOrderItArrived() {
        let buffer = TranscriptScrollBuffer(capacity: 10)
        buffer.append("chrome ----- -> T---- height=yes nearBottom=true armed=yes")
        buffer.append("status none -> shown")
        buffer.append("scroll site=chromeReassert nearBottom=true")

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(
            buffer.entries.map(\.text),
            [
                "chrome ----- -> T---- height=yes nearBottom=true armed=yes",
                "status none -> shown",
                "scroll site=chromeReassert nearBottom=true",
            ],
            """
            the buffer reordered or dropped what it was handed. Oldest first is not a preference here: \
            BUG-050 is a question about what happened *before* what
            """
        )
    }

    func testANewBufferIsEmptyAndSaysSo() {
        let buffer = TranscriptScrollBuffer(capacity: 4)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.exportText(), "")
    }

    // MARK: 2 — the cap

    func testTheBufferDropsItsOldestRatherThanRefusingNewLines() {
        let buffer = TranscriptScrollBuffer(capacity: 5)
        for index in 0..<12 {
            buffer.append("line \(index)")
        }
        XCTAssertEqual(buffer.count, 5, """
            the buffer holds \(buffer.count) of a 5-entry capacity. A log that stops recording once it is \
            full records the run-up and misses the event
            """)
        XCTAssertEqual(buffer.entries.map(\.text), ["line 7", "line 8", "line 9", "line 10", "line 11"])
    }

    /// The ring drops from the front, so an entry's *index* moves under it. The
    /// id must not: a `ForEach` keyed on a moving index draws the wrong row.
    func testIdsAreMonotonicAndSurviveEviction() {
        let buffer = TranscriptScrollBuffer(capacity: 3)
        for index in 0..<9 {
            buffer.append("line \(index)")
        }
        let ids = buffer.entries.map(\.id)
        XCTAssertEqual(ids, ids.sorted(), "ids came back out of order")
        XCTAssertEqual(Set(ids).count, ids.count, "two surviving entries share an id")
        XCTAssertEqual(ids.first, 6, """
            the ids restarted when the ring wrapped. They are the identity of a line, not its position
            """)
    }

    func testADegenerateCapacityIsClampedRatherThanCrashing() {
        let buffer = TranscriptScrollBuffer(capacity: 0)
        XCTAssertGreaterThanOrEqual(buffer.capacity, 1)
        buffer.append("one")
        buffer.append("two")
        XCTAssertEqual(buffer.entries.map(\.text), ["two"])
    }

    /// The shipped depth. Thirty seconds of the oscillation the report
    /// describes is a few dozen transitions; three hundred holds that with room
    /// for the run-up.
    func testTheShippedCapacityIsTheOneTheReportAskedFor() {
        XCTAssertEqual(TranscriptScrollBuffer.defaultCapacity, 300)
        XCTAssertEqual(TranscriptScrollBuffer.shared.capacity, TranscriptScrollBuffer.defaultCapacity)
    }

    // MARK: 3 — clear

    func testClearEmptiesTheBufferAndItKeepsRecordingAfterwards() {
        let buffer = TranscriptScrollBuffer(capacity: 8)
        buffer.append("before")
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty, "Clear left \(buffer.count) entries behind")
        XCTAssertEqual(buffer.exportText(), "")

        buffer.append("after")
        XCTAssertEqual(buffer.entries.map(\.text), ["after"], """
            the buffer stopped recording after a Clear. Clear is what the reader taps *before* running \
            the repro, so a buffer that does not come back is worse than no button
            """)
    }

    // MARK: 4 — export

    func testTheExportIsOneLinePerEntryWithATimestamp() {
        let buffer = TranscriptScrollBuffer(capacity: 8)
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        buffer.append("status none -> shown", at: start)
        buffer.append("status shown -> none", at: start.addingTimeInterval(0.4))

        let lines = buffer.exportText().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2, "the export was \(lines.count) lines for 2 entries")
        XCTAssertTrue(lines[0].hasSuffix("status none -> shown"), "line 0 lost its text: \(lines[0])")
        XCTAssertTrue(lines[1].hasSuffix("status shown -> none"), "line 1 lost its text: \(lines[1])")
        XCTAssertFalse(
            lines[0].hasPrefix("status"),
            """
            the exported line carries no timestamp. BUG-050 is a question about cadence — how often a \
            transition repeats — and a line with no clock on it cannot answer it
            """
        )
        XCTAssertNotEqual(String(lines[0]), String(lines[1]))
    }

    /// FEAT-002's rule for the diagnostics screen: a copy is worthless without
    /// the build it came from.
    func testTheHeaderIsPrependedAndSeparatedFromTheBody() {
        let buffer = TranscriptScrollBuffer(capacity: 4)
        buffer.append("status none -> shown")
        let export = buffer.exportText(header: "Hermes transcript scroll log · 0.2.0 (294)")
        let lines = export.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(lines[0]), "Hermes transcript scroll log · 0.2.0 (294)")
        XCTAssertEqual(String(lines[1]), "", "the header runs straight into the first entry")
        XCTAssertTrue(lines[2].hasSuffix("status none -> shown"))
    }

    func testAnEmptyHeaderIsNotDrawnAsABlankLine() {
        let buffer = TranscriptScrollBuffer(capacity: 4)
        buffer.append("only")
        XCTAssertEqual(buffer.exportText(header: ""), buffer.exportText())
    }

    // MARK: 5 — the live sink

    /// `TranscriptScrollLog` is the only writer, and the shared buffer is what
    /// Diagnostics draws. A notice-level line has to reach it or the section is
    /// a permanently empty box.
    func testTheLogMirrorsItsNoticeLevelLinesIntoTheSharedBuffer() {
        TranscriptScrollBuffer.shared.clear()

        TranscriptScrollLog.chromeTransition(
            from: "-----", to: "T----", changesHeight: true, isNearBottom: true, armed: true
        )
        TranscriptScrollLog.statusTransition(from: nil, to: "Thinking")
        TranscriptScrollLog.scroll(.chromeReassert, isNearBottom: true)

        let texts = TranscriptScrollBuffer.shared.entries.map(\.text)
        XCTAssertEqual(texts.count, 3, "the shared buffer holds \(texts.count) of 3 mirrored lines")
        XCTAssertTrue(texts[0].contains("chrome ----- -> T----"), "the chrome line lost its fingerprint: \(texts[0])")
        XCTAssertTrue(texts[0].contains("height=yes"))
        XCTAssertTrue(texts[0].contains("armed=yes"))
        XCTAssertEqual(texts[1], "status none -> shown")
        XCTAssertTrue(texts[2].contains("site=chromeReassert"))

        TranscriptScrollBuffer.shared.clear()
    }

    /// Deliberately **not** mirrored: it is one line per streaming delta, and
    /// three hundred of them arrive in a couple of seconds — evicting every
    /// chrome and status line, which are the ones the reader is looking for.
    /// This is the same set of lines `log stream` shows at its default level.
    func testThePerDeltaFollowScrollIsNotMirrored() {
        TranscriptScrollBuffer.shared.clear()
        for _ in 0..<50 {
            TranscriptScrollLog.scroll(.followTail, isNearBottom: true)
        }
        XCTAssertTrue(TranscriptScrollBuffer.shared.isEmpty, """
            \(TranscriptScrollBuffer.shared.count) follow-scrolls reached the buffer. At one per delta \
            they fill it during a single reply and the transitions BUG-050 is about are gone
            """)
    }

    /// A status transition that is not a transition writes nothing, and that
    /// guard has to hold on the buffer side too — it is called on every
    /// "Thinking · <tool>" flicker.
    func testAStatusNonTransitionIsNotRecorded() {
        TranscriptScrollBuffer.shared.clear()
        TranscriptScrollLog.statusTransition(from: "Thinking", to: "Running read")
        XCTAssertTrue(TranscriptScrollBuffer.shared.isEmpty, """
            "shown" to "shown" was recorded as a transition. The slot did not appear or disappear; only \
            its words changed, and the buffer would fill with noise
            """)
        TranscriptScrollBuffer.shared.clear()
    }
}

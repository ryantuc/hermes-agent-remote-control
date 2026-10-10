import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-089 and BUG-107 — the Artifacts scan presented a partial result as a whole one.
///
/// BUG-089: a session whose transcript fetch failed was skipped with `try? … else { continue }`, nothing counted it, and the screen read "Nothing here yet" or a short list as if every session had been read. BUG-107: each session was fetched once with `limit: 500` and no offset, and with an explicit limit the live route anchors at the OLDEST row (`hermes_cli/web_routers/sessions.py` `get_session_messages`: `latest_page = order == "latest" or (order is None and default_page)`, where `default_page = limit is None`), so everything after row 500 of a long session, which is where its recent artifacts are, was never read.
///
/// The fixture server pages exactly as that route does with an explicit limit and no `order`: oldest first, `offset` rows in, at most `limit` rows, `pagination.returned` the count it sent.
final class ArtifactScanTests: XCTestCase {

    // MARK: Fixtures

    /// A session's rows, `count` long, plain words except where `artifacts` puts a path into the text.
    static func rows(_ sessionID: String, count: Int, artifacts: [Int: String] = [:]) -> [TranscriptMessage] {
        (0..<count).map { index in
            let text = artifacts[index].map { "Saved the output to \($0) for you" } ?? "plain words, nothing produced"
            return TranscriptMessage(json: .object([
                "id": .number(Double(index + 1)),
                "session_id": .string(sessionID),
                "role": .string("assistant"),
                "content": .string(text),
                "timestamp": .number(Double(1_700_000_000 + index)),
            ]))
        }
    }

    /// Driven only from the main actor, one request at a time, so it needs no isolation of its own.
    private final class FixtureServer {
        var transcripts: [String: [TranscriptMessage]] = [:]
        var failing: Set<String> = []
        /// Answers every page with a full `limit` of rows whatever the offset, the way a server that ignores `offset` would.
        var ignoresOffset: Set<String> = []
        /// Throws `CancellationError` on the first request for this session.
        var cancelOn: String?
        private(set) var requests: [(sessionID: String, limit: Int, offset: Int)] = []

        func load(_ sessionID: String, _ limit: Int, _ offset: Int) async throws -> TranscriptPage {
            requests.append((sessionID, limit, offset))
            if sessionID == cancelOn { throw CancellationError() }
            if failing.contains(sessionID) { throw HermesError.malformedResponse("502 from the fixture") }
            if ignoresOffset.contains(sessionID) {
                let page = ArtifactScanTests.rows(sessionID, count: limit, artifacts: [0: "/out/same.png"])
                return TranscriptPage(sessionID: sessionID, messages: page, limit: limit, offset: offset, returned: page.count)
            }
            let all = transcripts[sessionID] ?? []
            let start = min(offset, all.count)
            let end = min(start + limit, all.count)
            let page = Array(all[start..<end])
            return TranscriptPage(sessionID: sessionID, messages: page, limit: limit, offset: offset, returned: page.count)
        }

        func offsets(for sessionID: String) -> [Int] {
            requests.filter { $0.sessionID == sessionID }.map(\.offset)
        }
    }

    private static func session(_ id: String) -> ArtifactScan.Session {
        ArtifactScan.Session(id: id, title: "Session \(id)")
    }

    // MARK: BUG-089 — a failed session is counted, not dropped

    @MainActor
    func testASessionWhoseFetchFailsIsCountedAndTheOthersStillScan() async throws {
        let server = FixtureServer()
        server.transcripts["a"] = Self.rows("a", count: 3, artifacts: [1: "/out/chart.png"])
        server.transcripts["c"] = Self.rows("c", count: 3, artifacts: [2: "/out/table.csv"])
        server.failing = ["b"]

        let outcome = await ArtifactScan.run(
            sessions: [Self.session("a"), Self.session("b"), Self.session("c")],
            loadPage: server.load
        )
        let result = try XCTUnwrap(outcome, "a scan that was not cancelled must publish its outcome")

        XCTAssertEqual(Set(result.records.map(\.value)), ["/out/chart.png", "/out/table.csv"],
                       "the sessions that did load must still be scanned")
        XCTAssertEqual(result.shortfall.unread, 1,
                       "the session whose fetch failed left no trace, so the list read as the whole of 3 sessions (BUG-089)")
        XCTAssertFalse(result.shortfall.isEmpty)
    }

    @MainActor
    func testEverySessionFailingIsReportedAsEverySessionUnread() async throws {
        let server = FixtureServer()
        server.failing = ["a", "b"]

        let outcome = await ArtifactScan.run(sessions: [Self.session("a"), Self.session("b")], loadPage: server.load)
        let result = try XCTUnwrap(outcome)

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.shortfall.unread, 2,
                       "two unreadable sessions rendered as \"Nothing here yet\", a positive claim the scan could not make")
    }

    // MARK: BUG-107 — a long session is read to its newest row

    @MainActor
    func testAnArtifactPastTheFirst500RowsIsFound() async throws {
        let server = FixtureServer()
        server.transcripts["long"] = Self.rows("long", count: 1_200, artifacts: [3: "/out/early.png", 1_150: "/out/recent.png"])

        let outcome = await ArtifactScan.run(sessions: [Self.session("long")], loadPage: server.load)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(Set(result.records.map(\.value)), ["/out/early.png", "/out/recent.png"],
                       "row 1,150 of a 1,200-row session was never fetched: the one explicit-limit page is the OLDEST 500 rows (BUG-107)")
        XCTAssertTrue(result.shortfall.isEmpty, "a session read to its end has no shortfall")
    }

    @MainActor
    func testALongSessionIsPagedOldestFirstUntilAShortPage() async {
        let server = FixtureServer()
        server.transcripts["long"] = Self.rows("long", count: 1_200)

        _ = await ArtifactScan.run(sessions: [Self.session("long")], loadPage: server.load)

        XCTAssertEqual(server.offsets(for: "long"), [0, 500, 1_000],
                       "pages must advance by what the server returned until it returns fewer rows than asked for")
        XCTAssertEqual(Set(server.requests.map(\.limit)), [500], "500 is the route's own clamp")
    }

    @MainActor
    func testASessionOfExactlyOnePageStopsOnTheEmptyPageAfterIt() async throws {
        let server = FixtureServer()
        server.transcripts["exact"] = Self.rows("exact", count: 500, artifacts: [499: "/out/last.png"])

        let outcome = await ArtifactScan.run(sessions: [Self.session("exact")], loadPage: server.load)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.records.map(\.value), ["/out/last.png"])
        XCTAssertLessThanOrEqual(server.offsets(for: "exact").count, 2,
                                 "a full page can only say \"maybe more\"; one more request settles it")
    }

    @MainActor
    func testAnArtifactNamedOnTwoPagesIsListedOnce() async throws {
        let server = FixtureServer()
        server.transcripts["repeat"] = Self.rows("repeat", count: 700, artifacts: [10: "/out/report.pdf", 650: "/out/report.pdf"])

        let outcome = await ArtifactScan.run(sessions: [Self.session("repeat")], loadPage: server.load)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.records.map(\.value), ["/out/report.pdf"],
                       "the scrape dedupes within one call; across pages the same `session:value` id would reach `ForEach` twice")
    }

    @MainActor
    func testAServerThatIgnoresTheOffsetCannotKeepTheScanRunning() async throws {
        let server = FixtureServer()
        server.ignoresOffset = ["stuck"]

        let outcome = await ArtifactScan.run(
            sessions: [Self.session("stuck")],
            pageSize: 10,
            pageCeiling: 5,
            loadPage: server.load
        )
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(server.offsets(for: "stuck").count, 5, "every page claims more, so only the ceiling ends the session")
        XCTAssertEqual(result.shortfall.truncated, 1,
                       "a session the scan stopped short of its end must be reported as not read to its end")
        XCTAssertEqual(result.records.map(\.value), ["/out/same.png"])
    }

    // MARK: Cancellation — a half-finished scan is not a result

    @MainActor
    func testACancelledScanPublishesNothing() async {
        let server = FixtureServer()
        server.transcripts["a"] = Self.rows("a", count: 3, artifacts: [0: "/out/first.png"])
        server.transcripts["c"] = Self.rows("c", count: 3, artifacts: [0: "/out/never.png"])
        server.cancelOn = "b"

        let outcome = await ArtifactScan.run(
            sessions: [Self.session("a"), Self.session("b"), Self.session("c")],
            loadPage: server.load
        )

        XCTAssertNil(outcome,
                     "leaving the screen cancels the scan; publishing what it had shows one session's artifacts as the whole list, and the next visit does not rescan")
    }

    // MARK: The note the screen draws

    @MainActor
    func testTheShortfallNoteNamesWhatWasNotRead() {
        XCTAssertNil(ArtifactScan.note(for: ArtifactScan.Shortfall(), of: 15), "a whole scan says nothing extra")

        XCTAssertEqual(ArtifactScan.note(for: ArtifactScan.Shortfall(unread: 3), of: 15),
                       "3 of 15 sessions couldn't be read, so this list may be missing what they produced.")
        XCTAssertEqual(ArtifactScan.note(for: ArtifactScan.Shortfall(truncated: 1), of: 15),
                       "1 session is longer than 50,000 messages; only its first 50,000 were scanned.")
        XCTAssertEqual(ArtifactScan.note(for: ArtifactScan.Shortfall(unread: 1, truncated: 2), of: 15),
                       "1 of 15 sessions couldn't be read, so this list may be missing what they produced. 2 sessions are longer than 50,000 messages; only their first 50,000 were scanned.")
    }
}

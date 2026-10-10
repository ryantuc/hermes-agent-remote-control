import XCTest

@testable import HermesServeKit

/// The prompt timeline routes' shapes (`hermes_cli/web_routers/sessions.py`, `hermes_state_timeline.py`): a page of prompt metadata with a cursor, and the window description beside a page of rows.
final class PromptTimelineTests: XCTestCase {

    func testATimelinePageDecodesItsEntriesAndCursor() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"session_id": "20261009_abc", "profile": "default",
         "entries": [
           {"row_id": 12, "preview": "Write me a summary", "timestamp": 1760000000.5},
           {"row_id": 40, "preview": "Now shorter", "timestamp": 1760000100}
         ],
         "pagination": {"limit": 500, "after_row_id": 0, "returned": 2, "total": 7, "has_more": true, "next_cursor": 40}}
        """.utf8))
        let page = PromptTimelinePage(json: json, requestedSessionID: "asked")
        XCTAssertEqual(page.sessionID, "20261009_abc")
        XCTAssertEqual(page.entries.map(\.rowID), [12, 40])
        XCTAssertEqual(page.entries.first?.preview, "Write me a summary")
        XCTAssertEqual(page.entries.first?.timestamp ?? 0, 1760000000.5, accuracy: 0.001)
        XCTAssertEqual(page.total, 7)
        XCTAssertEqual(page.nextCursor, 40)
        XCTAssertTrue(page.hasMore)
    }

    func testTheLastPageHasNoCursor() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"entries": [{"row_id": 3, "preview": "hi", "timestamp": 1}],
         "pagination": {"limit": 500, "after_row_id": 0, "returned": 1, "total": 1, "has_more": false, "next_cursor": null}}
        """.utf8))
        let page = PromptTimelinePage(json: json, requestedSessionID: "asked")
        XCTAssertEqual(page.sessionID, "asked", "a page without a session id is the one asked for")
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    func testTheWindowBesideAnAroundPageDecodes() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"session_id": "s", "messages": [],
         "pagination": {"row_id": 12, "limit": 120, "returned": 2, "order": "oldest", "offset": 30, "total": 200, "has_older": true, "has_newer": true}}
        """.utf8))
        let window = TranscriptWindow(json: json, rowID: 12)
        XCTAssertEqual(window.rowID, 12)
        XCTAssertEqual(window.offset, 30)
        XCTAssertEqual(window.total, 200)
        XCTAssertTrue(window.hasOlder)
        XCTAssertTrue(window.hasNewer)
    }

    /// FastAPI's unrouted 404 is `Not Found`; the session routes' own 404s say what was not found.
    func testOnlyABare404IsAMissingRoute() {
        XCTAssertTrue(RestAPI.isRouteMissing(HermesError.httpStatus(code: 404, message: "Not Found")))
        XCTAssertTrue(RestAPI.isRouteMissing(HermesError.httpStatus(code: 404, message: " not found ")))
        XCTAssertFalse(RestAPI.isRouteMissing(HermesError.httpStatus(code: 404, message: "Prompt not found")))
        XCTAssertFalse(RestAPI.isRouteMissing(HermesError.httpStatus(code: 404, message: "Session not found")))
        XCTAssertFalse(RestAPI.isRouteMissing(HermesError.httpStatus(code: 500, message: "Not Found")))
        XCTAssertFalse(RestAPI.isRouteMissing(HermesError.connectionClosed("gone")))
    }
}

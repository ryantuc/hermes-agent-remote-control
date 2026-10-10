import XCTest

@testable import HermesServeKit

/// Usage-limit reset time. `message.complete.error_surface.resets_at` is epoch seconds when the provider named when its limit lifts (`ErrorSurface`, `tui_gateway/contracts/events.py:162-172`, `:161-170` on an older backend). The client decoded `layer`, `code` and `retryable` only, so a 429 said "worth sending again" with no word on when.
final class ErrorSurfaceResetTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let english = Locale(identifier: "en_US")
    /// 2026-10-02 12:00:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_790_942_400)

    private func surface(_ resetsAt: JSONValue?) -> ErrorSurface? {
        var payload: [String: JSONValue] = [
            "layer": .string("provider"), "code": .string("rate_limited"), "retryable": .bool(true),
        ]
        if let resetsAt { payload["resets_at"] = resetsAt }
        return ErrorSurface(json: .object(payload))
    }

    func testTheResetMomentIsDecoded() {
        XCTAssertEqual(surface(.number(1_790_950_500))?.resetsAt, Date(timeIntervalSince1970: 1_790_950_500))
        XCTAssertNil(surface(nil)?.resetsAt, "most failures name no reset")
        XCTAssertNil(surface(.null)?.resetsAt)
        XCTAssertNil(surface(.number(0))?.resetsAt, "a non-positive moment is not a reset time")
        XCTAssertNil(surface(.string("soon"))?.resetsAt)
    }

    func testTheMessageCompleteFrameCarriesIt() {
        let payload: JSONValue = .object([
            "status": .string("error"), "error": .string("429 Too Many Requests"),
            "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limited"),
                                      "retryable": .bool(true), "resets_at": .number(1_790_950_500)]),
        ])
        guard case .messageComplete(let completion) = HermesEvent.project(
            GatewayEvent(type: "message.complete", sessionID: "s", payload: payload, params: .null)) else {
            return XCTFail("not a completion")
        }
        XCTAssertEqual(completion.errorSurface?.resetsAt, Date(timeIntervalSince1970: 1_790_950_500))
    }

    func testTheNoteNamesTheClockTimeToday() throws {
        let reset = try XCTUnwrap(surface(.number(1_790_950_500)))  // 14:15 UTC
        let note = try XCTUnwrap(reset.resetNote(now: noon, calendar: utc, locale: english))
        XCTAssertTrue(note.hasPrefix("The limit resets at "), note)
        XCTAssertTrue(note.contains("2:15"), note)
        XCTAssertFalse(note.contains("Oct"), "today needs no date: \(note)")
    }

    func testALaterDayIsNamed() throws {
        let reset = try XCTUnwrap(surface(.number(1_790_942_400 + 26 * 3600)))  // 2026-10-03 14:00 UTC
        let note = try XCTUnwrap(reset.resetNote(now: noon, calendar: utc, locale: english))
        XCTAssertTrue(note.hasPrefix("The limit resets "), note)
        XCTAssertTrue(note.contains("Oct 3"), note)
        XCTAssertTrue(note.contains("2:00"), note)
    }

    func testAPassedResetSaysItHasLifted() throws {
        let reset = try XCTUnwrap(surface(.number(1_790_942_400 - 600)))  // 11:50 UTC
        let note = try XCTUnwrap(reset.resetNote(now: noon, calendar: utc, locale: english))
        XCTAssertTrue(note.hasPrefix("The limit reset at "), note)
        XCTAssertTrue(note.contains("11:50"), note)
    }

    func testNoResetNoNote() {
        XCTAssertNil(surface(nil)?.resetNote(now: noon, calendar: utc, locale: english))
    }

    /// `ErrorSurface` is persisted inside checkpointed entries; one written before this field must still decode.
    func testAnOlderEncodedSurfaceStillDecodes() throws {
        let legacy = #"{"layer":"provider","code":"rate_limited","retryable":true}"#
        let decoded = try JSONDecoder().decode(ErrorSurface.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.resetsAt)
        let withReset = ErrorSurface(layer: "provider", code: "x", retryable: true, resetsAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try JSONDecoder().decode(ErrorSurface.self, from: JSONEncoder().encode(withReset)).resetsAt,
                       Date(timeIntervalSince1970: 5))
    }
}

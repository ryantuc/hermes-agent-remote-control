import Foundation
import XCTest

@testable import HermesMobile

/// BUG-095 (also BUG-146's `RelativeTime.swift:31` item) — a thread-list stamp ahead of the phone's clock read "just now" for as long as the skew lasted.
///
/// `RelativeTime.short` tested `interval < 45` before `interval < 0`, so every negative interval (a stamp in the future) returned "just now" and the future branch below it could never run. Future stamps are real on this wire: `last_active` is stamped by the server's clock, and `TurnElapsed` documents that nothing synchronises the two clocks. A backend ten minutes ahead pinned every row on Home, the hub, Bots and Command Center at "just now".
///
/// The assertions compare outputs with each other and with the one literal the function owns ("just now"), never with the formatter's English, so they hold in whatever locale the simulator runs.
final class RelativeTimeFutureTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAStampTenMinutesAheadIsNotJustNow() {
        let ahead = RelativeTime.short(now.addingTimeInterval(600), now: now)
        XCTAssertNotEqual(ahead, "just now", "a stamp ten minutes in the future is not \"just now\"; the label has to say it is ahead (BUG-095)")
        XCTAssertFalse(ahead.isEmpty, "a real future stamp must render something")
    }

    func testTheEpochSecondsEntryPointAgrees() {
        // Every list row calls this spelling, with `last_active` straight off the wire.
        let ahead = RelativeTime.short(epochSeconds: now.timeIntervalSince1970 + 3_600, now: now)
        XCTAssertNotEqual(ahead, "just now", "an hour ahead read \"just now\" through the epoch-seconds entry point")
    }

    func testAheadAndBehindByTheSameAmountReadDifferently() {
        let ahead = RelativeTime.short(now.addingTimeInterval(600), now: now)
        let behind = RelativeTime.short(now.addingTimeInterval(-600), now: now)
        XCTAssertNotEqual(ahead, behind, "ten minutes ahead and ten minutes ago are different facts and must not share a label")
    }

    func testSmallSkewEitherWayIsStillJustNow() {
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(30), now: now), "just now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-30), now: now), "just now")
    }

    func testAPastStampStillReadsAsRelative() {
        let behind = RelativeTime.short(now.addingTimeInterval(-600), now: now)
        XCTAssertNotEqual(behind, "just now")
        XCTAssertFalse(behind.isEmpty)
    }

    func testNoTimestampStillDrawsNothing() {
        XCTAssertEqual(RelativeTime.short(epochSeconds: 0, now: now), "")
        XCTAssertEqual(RelativeTime.short(Date(timeIntervalSince1970: 0), now: now), "")
    }
}

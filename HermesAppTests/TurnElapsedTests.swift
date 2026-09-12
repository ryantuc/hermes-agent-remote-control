import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-010 — the transcript's elapsed counter must answer "how long has this
/// turn been running", not "how long have I been watching it".
///
/// Those are the same number only for a turn you started on this phone and
/// never left. Leave the session and come back, reconnect, or attach mid-flight
/// to a turn a desktop or a cron run is driving, and the local stopwatch
/// restarts from zero while the turn is minutes old. The backend's
/// `turn_started_at` is the authority whenever it has spoken.
final class TurnElapsedTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_600)

    /// The case the feature exists for: the phone joined a turn that has
    /// already been running for eight minutes, and its own stopwatch says two.
    func testBackendStartWinsOverTheLocalStopwatch() {
        let backendStart = now.addingTimeInterval(-480)
        let localStart = now.addingTimeInterval(-120)

        XCTAssertEqual(
            TurnElapsed.seconds(backendStart: backendStart, localStart: localStart, now: now),
            480,
            accuracy: 0.001,
            "the turn is eight minutes old; two minutes is how long this client has watched"
        )
        XCTAssertEqual(TurnElapsed.origin(backendStart: backendStart, localStart: localStart), backendStart)
    }

    /// Re-entering a session re-stamps the local start and must not change the
    /// number, which is the whole complaint.
    func testReEnteringTheSessionDoesNotResetTheCount() {
        let backendStart = now.addingTimeInterval(-480)

        let firstVisit = TurnElapsed.seconds(
            backendStart: backendStart,
            localStart: now.addingTimeInterval(-470),
            now: now
        )
        let afterComingBack = TurnElapsed.seconds(
            backendStart: backendStart,
            localStart: now,
            now: now
        )

        XCTAssertEqual(afterComingBack, firstVisit, accuracy: 0.001)
        XCTAssertEqual(afterComingBack, 480, accuracy: 0.001)
    }

    /// No `turn_started_at` on the wire — an older backend, or an idle session
    /// whose value is null. Today's behaviour, unchanged.
    func testFallsBackToTheLocalStartWhenTheBackendIsSilent() {
        let localStart = now.addingTimeInterval(-120)

        XCTAssertEqual(
            TurnElapsed.seconds(backendStart: nil, localStart: localStart, now: now),
            120,
            accuracy: 0.001
        )
        XCTAssertEqual(TurnElapsed.origin(backendStart: nil, localStart: localStart), localStart)
    }

    /// Two unsynchronised clocks. A backend start a few seconds ahead of this
    /// phone is ordinary, and the honest reading is "just started" — never a
    /// negative duration, which `RelativeTime.duration` would happily render as
    /// "-3000 ms".
    func testAFutureBackendStartClampsToZero() {
        XCTAssertEqual(
            TurnElapsed.seconds(
                backendStart: now.addingTimeInterval(3),
                localStart: now.addingTimeInterval(-120),
                now: now
            ),
            0,
            accuracy: 0.001,
            "clock skew may not produce a negative elapsed time"
        )
    }

    /// The clamp is on the elapsed number, not on the choice of origin: a
    /// skewed backend start is still the start being counted from, so the
    /// counter begins ticking a moment later rather than jumping to the local
    /// stopwatch's much larger value.
    func testTheClampDoesNotFallBackToTheLocalStart() {
        let localStart = now.addingTimeInterval(-600)
        let skewed = now.addingTimeInterval(2)

        XCTAssertEqual(TurnElapsed.origin(backendStart: skewed, localStart: localStart), skewed)
        XCTAssertEqual(
            TurnElapsed.seconds(backendStart: skewed, localStart: localStart, now: now.addingTimeInterval(5)),
            3,
            accuracy: 0.001
        )
    }

    /// A local start in the future cannot happen, but the guard is on the
    /// result rather than on the backend branch, so prove it holds either way.
    func testAFutureLocalStartAlsoClampsToZero() {
        XCTAssertEqual(
            TurnElapsed.seconds(backendStart: nil, localStart: now.addingTimeInterval(5), now: now),
            0,
            accuracy: 0.001
        )
    }
}

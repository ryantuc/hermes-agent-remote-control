import XCTest

@testable import HermesServeKit

/// FEAT-019 ask 3 — the card's one remaining label.
///
/// The fields worth the space on the card are the title, `7/12`, the progress
/// bar and the elapsed timer; the backend name and the tool line are dropped.
/// The trap in that answer is that the tool line was the only place either
/// surface could say a
/// turn was over or had gone stale — it is the carrier for `"Done"`, the
/// failure status and `"No longer updating"`, and it is exactly the line
/// BUG-003's *"Working…, forever"* lived on.
///
/// These assertions are the guard on that. A widget body cannot be inspected in
/// a running view hierarchy, so the rule lives here as arithmetic, and what the
/// two widget bodies do is render the answer.
final class LiveActivityProgressLabelTests: XCTestCase {

    private func running(completed: Int, total: Int) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            title: "Rotate the logs",
            toolName: "Bash",
            toolDetail: "journalctl --vacuum-time=7d",
            toolsCompleted: completed,
            toolsTotal: total,
            isBusy: true
        )
    }

    func testARunningTurnShowsTheStepCounter() {
        XCTAssertEqual(
            LiveActivityDerivation.progressLabel(for: running(completed: 7, total: 12), isStale: false),
            "7/12"
        )
    }

    /// `0/0` is noise, and an empty string is what the widget hides the label
    /// on. A turn that has not called a tool yet gets the title, the timer and
    /// an empty bar, which is the honest picture.
    func testATurnWithNoToolCallsYetShowsNothing() {
        XCTAssertEqual(
            LiveActivityDerivation.progressLabel(for: running(completed: 0, total: 0), isStale: false),
            ""
        )
    }

    /// **The BUG-003 guard, rehomed.** With the tool line gone, a finished card
    /// whose label still read `7/12` would be indistinguishable from a running
    /// one — the exact failure the ended state was built to prevent.
    func testAFinishedTurnSaysSoRatherThanKeepingItsCounter() {
        let ended = LiveActivityDerivation.ended(running(completed: 12, total: 12), at: Date())
        XCTAssertEqual(LiveActivityDerivation.progressLabel(for: ended, isStale: false), "Done")
    }

    func testAFailedTurnKeepsItsOwnStatusWord() {
        let failed = LiveActivityDerivation.ended(running(completed: 3, total: 12), at: Date(), failed: true)
        XCTAssertEqual(LiveActivityDerivation.progressLabel(for: failed, isStale: false), "Failed")
    }

    /// A card the app can no longer update must say so — it is the only
    /// honesty available to a card whose process is gone, and after the trim
    /// this label is the only place left that can say it.
    func testAStaleCardSaysItIsNoLongerUpdating() {
        XCTAssertEqual(
            LiveActivityDerivation.progressLabel(for: running(completed: 7, total: 12), isStale: true),
            "No longer updating"
        )
    }

    /// Ended outranks stale, exactly as it does in `toolLine`: a turn that
    /// finished is the stronger and more specific claim than a card nobody has
    /// pushed to lately.
    func testEndedOutranksStale() {
        let ended = LiveActivityDerivation.ended(running(completed: 12, total: 12), at: Date())
        XCTAssertEqual(LiveActivityDerivation.progressLabel(for: ended, isStale: true), "Done")
    }

    /// `toolLine` is kept, not deleted — it is still the vocabulary the
    /// Settings roster sheet uses, and the two widget bodies simply stopped
    /// rendering it. A change that removed it would break the sheet silently.
    func testTheToolLineStillExistsForTheRosterSheet() {
        XCTAssertEqual(
            LiveActivityDerivation.toolLine(for: running(completed: 7, total: 12), isStale: false),
            "Bash · journalctl --vacuum-time=7d"
        )
    }
}

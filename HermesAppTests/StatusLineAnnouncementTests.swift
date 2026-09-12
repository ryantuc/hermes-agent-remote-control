import XCTest

@testable import HermesMobile

/// BUG-036 — the status ladder was silent to VoiceOver. `StatusLine` is a
/// combined accessibility element, which does not re-announce when its text
/// changes, and there were zero `UIAccessibility` call sites anywhere in the
/// app; a reader who sent a prompt and stayed on the transcript heard nothing
/// between their own message and the first streamed text.
///
/// The repair is an announcement posted on **phase edges only**. Whether the
/// post reaches a screen reader is not observable from a unit test — there is
/// no VoiceOver runtime in `HermesAppTests` — so the policy that decides *what*
/// gets announced is the oracle, and these are pure tests of it. The strings
/// below are the exact copy `ChatModel.statusLineText` emits.
final class StatusLineAnnouncementTests: XCTestCase {

    private let steered = "Steered — the current turn continues with your message"
    private let redirected = "Redirected — the current turn restarted with your message"
    private let queued = "Queued — waiting for the turn to start"

    func testPhaseChangeReturnsAnnouncementAndToolFlickerDoesNot() {
        // Every rung of the ladder announces when it is entered.
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: nil, to: "Sending…"),
            "Sending…",
            "the first rung of the send contract must be spoken"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: "Sending…", to: "Thinking"),
            "Thinking",
            "sending -> thinking is the edge that tells a reader the turn started"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: nil, to: queued),
            queued,
            "a queued send must be spoken — it is the state a reader is most likely to misread as done"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: "Thinking · bash", to: steered),
            steered,
            "a steer changes what the running turn is doing and must be spoken"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: steered, to: redirected),
            redirected,
            "steered and redirected are different outcomes, not one rung"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: "Thinking", to: "Working in another client · fixing the parser"),
            "Working in another client · fixing the parser",
            "a turn arriving from another client is the whole reason the row exists"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: "Working in another client", to: "Waiting for input in another client"),
            "Waiting for input in another client",
            "another client blocking on a human is a different rung from another client working"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: "Waiting for your answer", to: "Thinking"),
            "Thinking",
            "the turn resuming after an answer must be spoken"
        )
        XCTAssertEqual(
            StatusAnnouncement.announcement(from: "Thinking", to: "Waiting for your answer"),
            "Waiting for your answer",
            "a turn parked on the user is the one edge a reader cannot afford to miss"
        )

        // The throttle. Everything below is deliberately silent.
        XCTAssertNil(
            StatusAnnouncement.announcement(from: "Thinking", to: "Thinking · bash"),
            "tool names are movement inside the thinking rung; announcing them reads the whole run aloud"
        )
        XCTAssertNil(
            StatusAnnouncement.announcement(from: "Thinking · bash", to: "Thinking · read"),
            "one tool replacing another is the same rung"
        )
        XCTAssertNil(
            StatusAnnouncement.announcement(from: "Working in another client · fixing the parser", to: "Working in another client · writing the test"),
            "the foreign preview changes with every delta; the rung does not"
        )
        XCTAssertNil(
            StatusAnnouncement.announcement(from: steered, to: nil),
            "nil means a streaming bubble took the surface — the streamed text is the announcement"
        )
        XCTAssertNil(
            StatusAnnouncement.announcement(from: queued, to: queued),
            "the same status arriving twice is not an edge"
        )
        XCTAssertNil(
            StatusAnnouncement.announcement(from: nil, to: nil),
            "silence to silence says nothing"
        )
    }

    /// The map itself, stated once, so a future branch added to
    /// `statusLineText` that lands in the wrong rung fails here rather than
    /// only in the throttle assertions above.
    func testPhaseMapPlacesEveryStatusLineBranch() {
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: nil), .none)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Waiting for your answer"), .waitingAnswer)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: steered), .steered)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: redirected), .redirected)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Sending…"), .sending)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: queued), .queued)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Thinking"), .thinking)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Thinking · bash"), .thinking)
        // `live.statusText` is free-form backend copy; anything unrecognised is
        // work in progress, which is the thinking rung.
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Compacting the context"), .thinking)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Working in another client"), .foreignWorking)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Working in another client · preview"), .foreignWorking)
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Waiting for input in another client"), .foreignWaiting)
        // The foreign prefix rides in front of the busy copy, and the row is
        // about the other client, not about this one thinking.
        XCTAssertEqual(StatusAnnouncement.phase(forStatus: "Working in another client · Thinking · bash"), .foreignWorking)
    }
}

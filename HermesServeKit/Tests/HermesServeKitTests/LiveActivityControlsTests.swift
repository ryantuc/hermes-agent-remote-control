import Foundation
import XCTest

@testable import HermesServeKit

/// FEAT-019 — the arithmetic behind the Live Activity control surface.
///
/// The Lock Screen card and the Dynamic Island cannot be inspected in a running
/// view hierarchy, driven by `simctl`, or photographed off a tethered phone, so
/// the file this tests exists on the principle that anything about them decided
/// by arithmetic gets decided where a test can see it. Two rules land here: which
/// turns earn a card, and which of the two presentations a card may fill.
final class LiveActivityControlsTests: XCTestCase {

    // MARK: - When a card is earned

    func testEveryTurnAdmitsATurnThatIsSimplyRunning() {
        XCTAssertTrue(LiveActivityShowPolicy.everyTurn.admits(isBusy: true, hasBlockingPrompt: false))
    }

    func testQuestionsOnlyRefusesATurnThatIsSimplyRunning() {
        XCTAssertFalse(
            LiveActivityShowPolicy.questionsOnly.admits(isBusy: true, hasBlockingPrompt: false),
            "questions-only exists precisely to keep a plain running turn off the Lock Screen"
        )
    }

    /// The one settled positive: a question the agent is blocked on
    /// is always worth a card. Neither setting may switch it off — a picker
    /// that could is a picker that can hide the thing it was built to keep.
    func testBothPoliciesAdmitATurnBlockedOnAQuestion() {
        for policy in LiveActivityShowPolicy.allCases {
            XCTAssertTrue(
                policy.admits(isBusy: true, hasBlockingPrompt: true),
                "\(policy.rawValue) suppressed a card for a question the agent is waiting on"
            )
        }
    }

    /// A blocking prompt can outlive `isBusy` — an approval that arrives after
    /// the turn parked, a clarify the engine has already stopped counting as
    /// work — and the card is still the right answer.
    func testAQuestionEarnsACardEvenWhenTheTurnIsNotBusy() {
        for policy in LiveActivityShowPolicy.allCases {
            XCTAssertTrue(policy.admits(isBusy: false, hasBlockingPrompt: true))
        }
    }

    func testNoPolicyAdmitsASessionDoingNothing() {
        for policy in LiveActivityShowPolicy.allCases {
            XCTAssertFalse(
                policy.admits(isBusy: false, hasBlockingPrompt: false),
                "\(policy.rawValue) would put a card up for a session that is neither running nor asking"
            )
        }
    }

    /// The rule the default rides on: under `everyTurn` the admission clause is
    /// exactly the expression `LiveActivityController.deserves` used to carry
    /// inline, so the default changes nothing that already ships.
    func testEveryTurnIsTheOldInlineExpression() {
        for isBusy in [true, false] {
            for asking in [true, false] {
                XCTAssertEqual(
                    LiveActivityShowPolicy.everyTurn.admits(isBusy: isBusy, hasBlockingPrompt: asking),
                    isBusy || asking,
                    "everyTurn diverged from `isBusy || hasBlockingPrompt` at isBusy=\(isBusy) asking=\(asking)"
                )
            }
        }
    }

    func testThePolicyRawValuesAreTheStoredContract() {
        XCTAssertEqual(LiveActivityShowPolicy.everyTurn.rawValue, "everyTurn")
        XCTAssertEqual(LiveActivityShowPolicy.questionsOnly.rawValue, "questionsOnly")
        XCTAssertEqual(LiveActivityShowPolicy.allCases.count, 2)
    }

    // MARK: - The two presentations

    func testBothSurfacesOffIsEmptyAndNothingElseIs() {
        XCTAssertTrue(LiveActivitySurfaces(lockScreen: false, island: false).isEmpty)
        XCTAssertFalse(LiveActivitySurfaces(lockScreen: true, island: false).isEmpty)
        XCTAssertFalse(LiveActivitySurfaces(lockScreen: false, island: true).isEmpty)
        XCTAssertFalse(LiveActivitySurfaces.both.isEmpty)
    }

    func testASnapshotWithNoStatedSurfacesFillsBoth() {
        let snapshot = LiveActivitySnapshot(title: "Conversation")
        XCTAssertEqual(snapshot.shownSurfaces, .both)
        XCTAssertTrue(snapshot.showsOnLockScreen)
        XCTAssertTrue(snapshot.showsInIsland)
    }

    /// A Live Activity outlives the process that started it, so an app update
    /// can find a card whose archived content state was written before this
    /// field existed. It has to decode, and it has to decode to the behaviour
    /// that card was showing.
    func testAContentStateEncodedWithoutSurfacesStillDecodes() throws {
        let current = LiveActivitySnapshot(
            title: "Conversation",
            isBusy: true,
            surfaces: LiveActivitySurfaces(lockScreen: false, island: false)
        )
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        XCTAssertNotNil(payload["surfaces"], "precondition: the field is not being encoded, so stripping it proves nothing")
        payload.removeValue(forKey: "surfaces")

        let decoded = try JSONDecoder().decode(
            LiveActivitySnapshot.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(decoded.shownSurfaces, .both, "an older card decoded to something other than the card it was")
    }

    func testTheChosenSurfacesSurviveACodingRoundTrip() throws {
        let snapshot = LiveActivitySnapshot(
            title: "Conversation",
            isBusy: true,
            surfaces: LiveActivitySurfaces(lockScreen: false, island: true)
        )
        let decoded = try JSONDecoder().decode(
            LiveActivitySnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertFalse(decoded.showsOnLockScreen)
        XCTAssertTrue(decoded.showsInIsland)
    }

    /// The wind-down strips everything interactive off a finished card. It must
    /// not also hand a surface back: a card that spent its whole life reduced
    /// cannot suddenly print the chat's title on its way out.
    func testTheEndedSnapshotKeepsTheSurfacesItWasShowing() {
        let live = LiveActivitySnapshot(
            title: "Rotating the logs",
            toolName: "bash",
            isBusy: true,
            surfaces: LiveActivitySurfaces(lockScreen: false, island: true)
        )
        let ended = LiveActivityDerivation.ended(live, at: Date())
        XCTAssertFalse(ended.showsOnLockScreen)
        XCTAssertTrue(ended.showsInIsland)
    }

    func testTheDerivationCarriesTheSurfacesItIsGiven() {
        var state = SessionTurnState()
        state.isBusy = true
        let snapshot = LiveActivityDerivation.snapshot(
            from: state,
            title: "Rotating the logs",
            startedAt: Date(),
            surfaces: LiveActivitySurfaces(lockScreen: true, island: false)
        )
        XCTAssertTrue(snapshot.showsOnLockScreen)
        XCTAssertFalse(snapshot.showsInIsland)
    }

    func testTheDerivationStillDefaultsToBothSurfaces() {
        var state = SessionTurnState()
        state.isBusy = true
        let snapshot = LiveActivityDerivation.snapshot(from: state, title: "Conversation", startedAt: Date())
        XCTAssertEqual(snapshot.shownSurfaces, .both)
    }

    // MARK: - The reduced line

    /// The reduced card's only text. Every branch returns a constant, and that
    /// is the assertion worth making: there is no path from session content to
    /// this string, which is what makes "no chat title, no tool, no command"
    /// checkable rather than a promise.
    func testTheReducedLineNeverRepeatsAnythingFromTheSession() {
        let loud = LiveActivitySnapshot(
            title: "Quarterly numbers",
            toolName: "bash",
            toolDetail: "rm -rf /var/log/secret",
            isBusy: true,
            statusText: "Reading payroll.csv",
            approvalToken: "token",
            approvalCommand: "cat ~/.ssh/id_rsa",
            approvalDescription: "read the private key"
        )
        let line = LiveActivityDerivation.reducedLine(for: loud, isStale: false)
        for leak in ["Quarterly numbers", "bash", "rm -rf", "payroll", "id_rsa", "private key"] {
            XCTAssertFalse(line.contains(leak), "the reduced Lock Screen line leaked \"\(leak)\"")
        }
        XCTAssertEqual(line, "Waiting for you")
    }

    func testTheReducedLineNamesTheStateItIsIn() {
        var busy = LiveActivitySnapshot(isBusy: true)
        XCTAssertEqual(LiveActivityDerivation.reducedLine(for: busy, isStale: false), "Running")

        XCTAssertEqual(
            LiveActivityDerivation.reducedLine(for: LiveActivitySnapshot(isBusy: false), isStale: false),
            "Idle"
        )
        XCTAssertEqual(
            LiveActivityDerivation.reducedLine(for: busy, isStale: true),
            "No longer updating",
            "a card the app can no longer update must say so on the reduced surface too"
        )

        busy.endedAt = Date()
        XCTAssertEqual(
            LiveActivityDerivation.reducedLine(for: busy, isStale: true),
            "Finished",
            "ended is the stronger, more specific claim and outranks stale — same order as `toolLine`"
        )
    }
}

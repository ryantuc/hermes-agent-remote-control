import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-062 B, the pure half: how a parked question is written into the content state and read back out of it by the widget.
///
/// The content state is the kit's `LiveActivitySnapshot`, which has no field for the kind of question, so the line rides in `statusText` under an invariant the controller keeps. These pin that invariant, and the rule that nothing the widget prints for a parked question comes from session content.
@MainActor
final class ParkedQuestionSnapshotTests: XCTestCase {

    private func busy(status: String = "", tool: String = "clarify", detail: String = "Which branch?") -> LiveActivitySnapshot {
        LiveActivitySnapshot(title: "Deploy", toolName: tool, toolDetail: detail, toolsCompleted: 2, toolsTotal: 3, isBusy: true, statusText: status)
    }

    // MARK: Writing

    func testParkingWritesTheLineAndBlanksTheToolFields() {
        let parked = ParkedQuestion.applying(.answer, to: busy())
        XCTAssertEqual(parked.statusText, "Waiting for your answer")
        XCTAssertEqual(parked.toolName, "", "the running tool is the question itself")
        XCTAssertEqual(parked.toolDetail, "", "the question text must never reach lock-screen glass")
        XCTAssertEqual(parked.parkedQuestion, .answer)
        XCTAssertTrue(parked.isBusy, "the turn is still running; the wait is a state of it, not its end")
        XCTAssertEqual(parked.toolsCompleted, 2)
        XCTAssertEqual(parked.toolsTotal, 3)
    }

    func testADesktopRequestWritesItsOwnLine() {
        let parked = ParkedQuestion.applying(.desktop, to: busy())
        XCTAssertEqual(parked.statusText, "Continue in Desktop")
        XCTAssertEqual(parked.parkedQuestion, .desktop)
    }

    /// The invariant that lets the widget trust a match: with nothing parked, backend status copy that happens to equal a line is dropped.
    func testWithNothingParkedACollidingStatusIsDropped() {
        for question in ParkedQuestion.allCases {
            let unparked = ParkedQuestion.applying(nil, to: busy(status: question.line))
            XCTAssertEqual(unparked.statusText, "", "\(question): a backend status that equals a parked line would read as a question the registry does not have")
            XCTAssertNil(unparked.parkedQuestion)
        }
    }

    func testWithNothingParkedOrdinaryStatusIsKept() {
        let unparked = ParkedQuestion.applying(nil, to: busy(status: "Compressing context"))
        XCTAssertEqual(unparked.statusText, "Compressing context")
        XCTAssertEqual(unparked.toolName, "clarify", "nothing parked means nothing to blank")
    }

    // MARK: Reading

    func testAnEndedCardIsNeverParked() {
        let ended = LiveActivityDerivation.ended(ParkedQuestion.applying(.answer, to: busy()), at: Date())
        XCTAssertNil(ended.parkedQuestion)
        XCTAssertFalse(ended.isWaitingOnPerson)
    }

    /// An approval keeps its own copy and buttons, so a parked line under an approval token is not read as a second claim.
    func testAnApprovalOutranksTheParkedLine() {
        var snapshot = ParkedQuestion.applying(.answer, to: busy())
        snapshot.approvalToken = UUID().uuidString
        XCTAssertNil(snapshot.parkedQuestion)
        XCTAssertTrue(snapshot.isWaitingOnPerson)
    }

    func testEveryLineRoundTrips() {
        for question in ParkedQuestion.allCases {
            XCTAssertEqual(ParkedQuestion(line: question.line), question)
        }
        XCTAssertNil(ParkedQuestion(line: ""))
        XCTAssertNil(ParkedQuestion(line: "Working…"))
    }

    // MARK: The reduced card

    func testTheReducedCardSaysWaitingForYouAndNothingElse() {
        let parked = ParkedQuestion.applying(.answer, to: busy())
        XCTAssertEqual(ParkedQuestion.reducedLine(for: parked, isStale: false), "Waiting for you")
        XCTAssertEqual(ParkedQuestion.reducedLine(for: ParkedQuestion.applying(.desktop, to: busy()), isStale: false), "Waiting for you")
    }

    func testStaleAndEndedOutrankTheWaitOnTheReducedCard() {
        let parked = ParkedQuestion.applying(.answer, to: busy())
        XCTAssertEqual(ParkedQuestion.reducedLine(for: parked, isStale: true), "No longer updating")
        XCTAssertEqual(ParkedQuestion.reducedLine(for: LiveActivityDerivation.ended(parked, at: Date()), isStale: false), "Finished")
    }

    func testAnUnparkedReducedCardIsUnchanged() {
        let running = busy()
        XCTAssertEqual(ParkedQuestion.reducedLine(for: running, isStale: false), LiveActivityDerivation.reducedLine(for: running, isStale: false))
        XCTAssertEqual(ParkedQuestion.reducedLine(for: running, isStale: false), "Running")
    }

    /// The reduced card exists so a person can switch the Lock Screen card off and leak nothing; a parked question must not open a path from session strings.
    func testNoSessionContentReachesTheReducedLine() {
        let secret = "sk-" + "live-SYNTHETIC"
        var snapshot = ParkedQuestion.applying(.answer, to: busy(tool: secret, detail: secret))
        snapshot.title = secret
        let line = ParkedQuestion.reducedLine(for: snapshot, isStale: false)
        XCTAssertFalse(line.contains(secret))
        XCTAssertFalse(snapshot.statusText.contains(secret))
    }

    // MARK: The controller's mapping

    func testOnlyNonApprovalPromptsPark() {
        XCTAssertNil(LiveActivityController.parkedQuestion(for: .approval), "an approval has its own card and the only buttons a card may carry")
        XCTAssertNil(LiveActivityController.parkedQuestion(for: nil))
        XCTAssertEqual(LiveActivityController.parkedQuestion(for: .clarify), .answer)
        XCTAssertEqual(LiveActivityController.parkedQuestion(for: .sudo), .answer)
        XCTAssertEqual(LiveActivityController.parkedQuestion(for: .secret), .answer)
        XCTAssertEqual(LiveActivityController.parkedQuestion(for: .desktop), .desktop)
    }
}

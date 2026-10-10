import XCTest

@testable import HermesMobile

/// Small behaviours other slices left for each other: the model drawer's opening search, the Photos repair line, and a connector sign-in marking its chat as waiting.
@MainActor
final class FollowUpMountTests: XCTestCase {

    // MARK: "/model <text>" opens the drawer pre-searched

    func testAModelCommandThatMatchedNothingOpensTheDrawerWithItsTextAsTheSearch() {
        XCTAssertEqual(ModelCommand.searchText(for: .select("sonnet 9")), "sonnet 9")
        XCTAssertEqual(ModelCommand.searchText(for: .picker), "")
    }

    // MARK: The Photos repair line names the app as iOS lists it

    func testThePhotosRepairLineNamesHARC() {
        let note = PhotoSave.State.denied.note ?? ""
        XCTAssertTrue(note.contains("iOS Settings › HARC › Photos"), note)
        XCTAssertFalse(note.contains("Settings › Hermes"), note)
    }

    // MARK: A connector sign-in marks its chat

    func testASignInWithNoOtherPromptMarksItsSessionAsWaiting() {
        let waiting = LiveActivityController.waitingPrompts([:], signIns: ["rt-signin"])
        XCTAssertEqual(waiting, ["rt-signin": .signIn])
    }

    func testABlockingPromptOutranksASignInOnTheSameSession() {
        let waiting = LiveActivityController.waitingPrompts(["rt-both": .approval, "rt-q": .clarify], signIns: ["rt-both"])
        XCTAssertEqual(waiting, ["rt-both": .approval, "rt-q": .clarify])
    }

    func testTheOtherChatBannerAnnouncesASignIn() {
        let banner = ElsewherePrompt.pick(
            waiting: ["rt-other": .signIn],
            currentRuntimeID: "rt-open",
            currentStoredID: "s-open",
            storedID: { ["rt-other": "s-other", "rt-open": "s-open"][$0] },
            title: { $0 == "s-other" ? "Fix the build" : "" }
        )
        XCTAssertEqual(banner?.kind, .signIn)
        XCTAssertEqual(banner?.headline, "Hermes needs you to sign in in another chat")
    }

    func testAnApprovalElsewhereStillLeadsASignIn() {
        let banner = ElsewherePrompt.pick(
            waiting: ["rt-a": .signIn, "rt-b": .approval],
            currentRuntimeID: nil,
            currentStoredID: nil,
            storedID: { ["rt-a": "s-a", "rt-b": "s-b"][$0] },
            title: { _ in "" }
        )
        XCTAssertEqual(banner?.kind, .approval)
        XCTAssertEqual(banner?.others, 1)
    }

    func testHomeMarksASignInRowAsNeedingASignIn() {
        XCTAssertEqual(HomeWaitingMark.label(for: .signIn), "Sign in needed")
        XCTAssertEqual(HomeWaitingMark.label(for: .clarify), "Needs your answer")
        XCTAssertEqual(HomeWaitingMark.label(for: .desktop), "Continue in Desktop")
    }

    func testTheSignInKindSpeaksAsTheSignInNotice() {
        XCTAssertEqual(ApprovalNotifications.PromptKind.signIn.title, ApprovalNotifications.signInTitle)
        XCTAssertEqual(ApprovalNotifications.PromptKind.signIn.body, ApprovalNotifications.signInBody)
    }

    func testASignInIsNotAParkedQuestionOnTheLockScreenCard() {
        XCTAssertNil(LiveActivityController.parkedQuestion(for: .signIn))
    }
}

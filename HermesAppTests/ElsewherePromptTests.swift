import XCTest

@testable import HermesMobile

/// BUG-062 C, the in-chat half: a question Hermes is waiting on in another conversation was presented nowhere while the person was reading this one; the backend's timeout then answered it for them. Home already had its "Needs your answer" mark from the current-request registry (`LiveActivityController.waiting`); the open chat now announces the same registry entry in a banner under its bar, and a tap opens the waiting conversation.
@MainActor
final class ElsewherePromptTests: XCTestCase {

    private let titles = ["s-other": "Fix the build", "s-second": "Write the release notes", "s-open": "This chat"]

    private func pick(
        _ waiting: [String: ApprovalNotifications.PromptKind],
        runtime: String? = "rt-open",
        stored: String? = "s-open",
        map: [String: String] = ["rt-other": "s-other", "rt-second": "s-second", "rt-open": "s-open"]
    ) -> ElsewherePrompt? {
        ElsewherePrompt.pick(
            waiting: waiting,
            currentRuntimeID: runtime,
            currentStoredID: stored,
            storedID: { map[$0] },
            title: { self.titles[$0] ?? "" }
        )
    }

    func testAQuestionInAnotherConversationIsAnnounced() {
        XCTAssertEqual(
            pick(["rt-other": .clarify]),
            ElsewherePrompt(storedID: "s-other", title: "Fix the build", kind: .clarify, others: 0),
            "a clarify parked in another conversation is announced nowhere in this one (BUG-062 C)"
        )
    }

    func testTheOpenConversationsOwnQuestionIsNotAnnouncedAgain() {
        XCTAssertNil(pick(["rt-open": .approval]), "the chat already shows its own prompt; a banner would point at itself")
    }

    /// A chat whose runtime id is not known yet (a draft binding, a reconnect) is still recognised by its durable id.
    func testTheOpenConversationIsRecognisedByItsDurableIdToo() {
        XCTAssertNil(pick(["rt-open": .clarify], runtime: nil))
    }

    func testAnApprovalOutranksAQuestionAndTheRestAreCounted() {
        let banner = pick(["rt-other": .clarify, "rt-second": .approval])
        XCTAssertEqual(banner?.storedID, "s-second", "the approval, which fails closed on a short fuse, must lead")
        XCTAssertEqual(banner?.kind, .approval)
        XCTAssertEqual(banner?.others, 1)
    }

    /// A session this phone has no durable id for cannot be opened, so it is not offered.
    func testASessionThatCannotBeOpenedIsNotAnnounced() {
        XCTAssertNil(pick(["rt-unknown": .clarify]))
    }

    func testTheCopy() {
        let banner = ElsewherePrompt(storedID: "s-other", title: "Fix the build", kind: .clarify, others: 0)
        XCTAssertEqual(banner.headline, "Hermes has a question in another chat")
        XCTAssertEqual(banner.detail, "Fix the build")
        let several = ElsewherePrompt(storedID: "s-other", title: "Fix the build", kind: .approval, others: 2)
        XCTAssertEqual(several.headline, "Hermes needs approval in another chat")
        XCTAssertEqual(several.detail, "Fix the build · 2 more waiting")
        let desktop = ElsewherePrompt(storedID: "s-other", title: "", kind: .desktop, others: 0)
        XCTAssertEqual(desktop.headline, "Another chat is waiting on Desktop")
        XCTAssertEqual(desktop.detail, "Untitled chat")
    }
}

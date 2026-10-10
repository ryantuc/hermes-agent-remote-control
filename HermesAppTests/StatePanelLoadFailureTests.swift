import XCTest

@testable import HermesMobile

/// The load-failure panel the backend-backed screens mount (Artifacts, Capabilities, Command Center, and the two Settings screens once mounted): it says what failed, offers Try again only when a backend could answer it, and with none says to connect one instead of repeating the transport's "Not connected to a backend."
@MainActor
final class StatePanelLoadFailureTests: XCTestCase {
    func testWithABackendThePanelShowsTheErrorAndOffersTryAgain() {
        let panel = StatePanel.loadFailure(title: "Couldn't scan sessions", error: "The request timed out.", hasBackend: true) {}
        XCTAssertEqual(panel.title, "Couldn't scan sessions")
        XCTAssertEqual(panel.message, "The request timed out.")
        XCTAssertEqual(panel.actionTitle, "Try again")
        XCTAssertNotNil(panel.action)
    }

    func testWithNoBackendThePanelSaysToConnectOneAndOffersNoRetry() {
        let panel = StatePanel.loadFailure(title: "Couldn't load capabilities", error: "Not connected to a backend.", hasBackend: false) {}
        XCTAssertEqual(panel.message, LoadFailureRecovery.noBackendMessage)
        XCTAssertNil(panel.action, "Try again with no backend can only fail again")
    }

    func testTryAgainRunsTheScreensOwnRetry() {
        var retried = 0
        let panel = StatePanel.loadFailure(title: "Couldn't load sessions", error: "Server error", hasBackend: true) { retried += 1 }
        panel.action?()
        XCTAssertEqual(retried, 1)
    }
}

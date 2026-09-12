import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// **BUG-111 — the contract-version warning was written and never read.**
///
/// `grep -rn contractWarning` across `HermesApp/` and `HermesServeKit/` returned three hits on the unfixed tree: the declaration on `AppModel` and the two assignments inside `checkContract`. No view, no test, nothing. The check itself was sound — the app's one protocol-compatibility diagnostic simply went nowhere, so a user on a pre-v4 backend got unexplained breakage instead of the sentence the app had already written for them.
///
/// Rendering it raises a second question the dead property never had to answer: what happens on the next `session.info`, which arrives on every resume. A notice that re-raises itself after being dismissed is a permanent bar; one that latches dismissed forever is silence again the moment the reader changes backends. `ContractNotice` owns both halves so they cannot drift apart in two files.
///
/// `@MainActor` on the class because `AppModel.minimumDesktopContract` is a static on a `@MainActor` type, and the notice's own rules are stated against that number rather than against a copy of it.
@MainActor
final class ContractNoticeTests: XCTestCase {

    private let minimum = AppModel.minimumDesktopContract

    // MARK: 1 — when it speaks

    func testAnOlderBackendEarnsAWarningThatNamesBothVersions() {
        var notice = ContractNotice()
        notice.update(backendContract: 2, minimum: minimum)
        guard let message = notice.message else {
            return XCTFail("a backend two contract versions behind said nothing at all")
        }
        XCTAssertTrue(message.contains("v2"), "the warning does not say what the backend reported: \(message)")
        XCTAssertTrue(
            message.contains("v\(minimum)"),
            "the warning does not say what this client needs: \(message)"
        )
    }

    func testACurrentOrNewerBackendSaysNothing() {
        for reported in [minimum, minimum + 1, minimum + 9] {
            var notice = ContractNotice()
            notice.update(backendContract: reported, minimum: minimum)
            XCTAssertNil(notice.message, """
                a backend reporting contract v\(reported) against a minimum of v\(minimum) was told it is \
                out of date
                """)
        }
    }

    /// The guard that makes the check safe on old backends, restated where a
    /// reader will find it. `SessionAPI.swift:103` decodes a missing key as
    /// `coercedInt ?? 0`, and 0 means "did not say", not "said something old".
    /// `AppModel.checkContract` refuses to consult the notice at all in that
    /// case; this asserts the sentence it would have produced is the alarming
    /// one, so nobody removes the guard on the grounds that it is redundant.
    func testAZeroWouldBeAlarmingWhichIsWhyTheCallerGuardsIt() {
        var notice = ContractNotice()
        notice.update(backendContract: 0, minimum: minimum)
        XCTAssertNotNil(notice.message, """
            0 no longer produces a warning here. That is not an improvement — it means \
            `AppModel.checkContract`'s `guard info.desktopContract > 0` looks redundant and will be \
            deleted, and the day the arithmetic changes every backend that predates the field starts \
            being called out of date
            """)
    }

    // MARK: 2 — dismissal

    func testDismissingClearsTheNotice() {
        var notice = ContractNotice()
        notice.update(backendContract: 2, minimum: minimum)
        notice.dismiss()
        XCTAssertNil(notice.message)
    }

    /// `session.info` arrives on every resume. A notice that comes back each
    /// time is a bar the reader cannot clear, which is worse than the silence
    /// BUG-111 is fixing.
    func testADismissedWarningDoesNotComeBackOnTheNextSessionInfo() {
        var notice = ContractNotice()
        notice.update(backendContract: 2, minimum: minimum)
        notice.dismiss()
        for _ in 0..<5 {
            notice.update(backendContract: 2, minimum: minimum)
        }
        XCTAssertNil(notice.message, """
            the notice re-raised itself after being dismissed. `session.info` lands on every resume, so \
            this is a permanent strip across the top of every screen
            """)
    }

    /// A different answer is a different sentence, and the reader has not seen
    /// it. Dismissing "v2" must not silence "v1".
    func testADismissalDoesNotSilenceADifferentWarning() {
        var notice = ContractNotice()
        notice.update(backendContract: 2, minimum: minimum)
        notice.dismiss()
        notice.update(backendContract: 1, minimum: minimum)
        XCTAssertNotNil(notice.message, """
            a dismissal of one version's warning silenced another version's. The reader waved away a \
            sentence, not the subject
            """)
        XCTAssertEqual(notice.message?.contains("v1"), true)
    }

    /// Connecting to a current backend clears the dismissal as well as the
    /// message, so going back to the old one says it again.
    func testConnectingToACurrentBackendResetsTheDismissal() {
        var notice = ContractNotice()
        notice.update(backendContract: 2, minimum: minimum)
        notice.dismiss()
        notice.update(backendContract: minimum, minimum: minimum)
        XCTAssertNil(notice.message)

        notice.update(backendContract: 2, minimum: minimum)
        XCTAssertNotNil(notice.message, """
            after a healthy backend cleared the state, the old backend's warning stayed suppressed. \
            The dismissal was about one connection; this is a different one
            """)
    }

    /// Dismissing when there is nothing to dismiss must not poison the next
    /// real warning.
    func testDismissingNothingDoesNotSuppressTheNextWarning() {
        var notice = ContractNotice()
        notice.dismiss()
        notice.update(backendContract: 2, minimum: minimum)
        XCTAssertNotNil(notice.message, """
            a dismissal made against an empty notice swallowed the first real one. `dismissed` was set \
            to nil and nil then matched the absence of a warning
            """)
    }

    // MARK: 3 — the model's surface

    /// The property the banner reads. It was `private(set)` and unread; it is
    /// now derived, and the dismissal has to be reachable from a view.
    func testTheModelExposesTheNoticeAndAWayToDismissIt() async {
        let harness = await AppHarness.make()
        XCTAssertNil(harness.app.contractWarning, "a fresh model is warning about a backend it has not met")
        harness.app.dismissContractWarning()
        XCTAssertNil(harness.app.contractWarning)
        await harness.tearDown()
    }

    func testTheClientsMinimumIsTheDesktopsRequiredContract() {
        XCTAssertEqual(AppModel.minimumDesktopContract, 4, """
            the minimum moved. The desktop refuses to drive a backend below its required contract \
            (jsonrpc-methods §6.1) and this client warns instead; the number the two disagree about \
            should be one number
            """)
    }
}

import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-004 (privacy policy) and FEAT-005 (contact/support). Both rows are
/// driven by one constants site, and a link that has not been supplied yet
/// must draw no row at all.
final class AboutLinkRowTests: XCTestCase {

    private let policy = URL(string: "https://example.invalid/privacy")!
    private let support = URL(string: "mailto:support@example.invalid")!

    func testNoLinksMeansNoRows() {
        XCTAssertEqual(
            AboutLinkRow.visibleRows(privacyPolicy: nil, support: nil),
            [],
            "an unset link must hide its row, not draw a dead one"
        )
    }

    func testEachRowAppearsOnlyWhenItsOwnLinkIsSet() {
        XCTAssertEqual(AboutLinkRow.visibleRows(privacyPolicy: policy, support: nil), [.privacyPolicy])
        XCTAssertEqual(AboutLinkRow.visibleRows(privacyPolicy: nil, support: support), [.support])
        XCTAssertEqual(AboutLinkRow.visibleRows(privacyPolicy: policy, support: support), [.privacyPolicy, .support])
    }

    func testARowOpensItsOwnLink() {
        XCTAssertEqual(AboutLinkRow.privacyPolicy.url(privacyPolicy: policy, support: support), policy)
        XCTAssertEqual(AboutLinkRow.support.url(privacyPolicy: policy, support: support), support)
    }

    func testTheRowsAreNamedForWhatAppReviewLooksFor() {
        XCTAssertEqual(AboutLinkRow.privacyPolicy.title, "Privacy Policy")
        XCTAssertEqual(AboutLinkRow.support.title, "Contact & Support")
    }
}

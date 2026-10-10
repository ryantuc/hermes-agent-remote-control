import Foundation
import XCTest

@testable import HermesMobile

/// The three links a public build draws on the first-run screen and in About. App Review requires a privacy policy reachable from inside the app (5.1.1(i)) and a way to contact the developer (1.5); both are pages of the repository's GitHub Pages site, so their addresses follow from the account and repository name.
@MainActor
final class ShippedLinksTests: XCTestCase {

    private static let site = "https://ryantuc.github.io/hermes-agent-remote-control/"

    func testThePrivacyPolicyLinkIsThePublishedPolicy() throws {
        let url = try XCTUnwrap(HermesLinks.privacyPolicy, "a public build with no privacy policy link fails guideline 5.1.1(i)")
        XCTAssertEqual(url.absoluteString, Self.site + "privacy.html")
    }

    func testTheSupportLinkIsThePublishedSupportPage() throws {
        let url = try XCTUnwrap(HermesLinks.support, "a public build with no support link fails guideline 1.5")
        XCTAssertEqual(url.absoluteString, Self.site + "support.html")
    }

    func testTheGitHubLinkIsThePublicRepository() throws {
        let url = try XCTUnwrap(HermesLinks.github)
        XCTAssertEqual(url.absoluteString, "https://github.com/ryantuc/hermes-agent-remote-control")
    }

    /// The old repository stays private for good, so a link to it is a dead link for every reviewer and user.
    func testNoShippedLinkPointsAtTheRetiredRepository() {
        for url in [HermesLinks.github, HermesLinks.privacyPolicy, HermesLinks.support].compactMap({ $0 }) {
            XCTAssertFalse(url.absoluteString.contains("hermes-mobile"), "\(url) points at the retired private repository")
            XCTAssertEqual(url.scheme, "https", "\(url) is not https")
        }
    }

    func testFirstRunAndAboutDrawAllThreeLinks() {
        XCTAssertEqual(FirstRunLinkRow.visibleRows(), [.github, .privacyPolicy, .support])
        let entries = AboutSupportEntry.entries()
        XCTAssertTrue(entries.contains(.link(.privacyPolicy)), "About has no Privacy Policy row")
        XCTAssertTrue(entries.contains(.link(.support)), "About has no Contact & Support row")
    }
}

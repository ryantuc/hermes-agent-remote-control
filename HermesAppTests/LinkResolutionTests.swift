import Foundation
import XCTest

@testable import HermesMobile

/// BUG-146, three reading findings about links.
///
/// `AboutView.swift` and `HomeView.swift`: the rows were decided from injectable link values and then drawn with URLs re-read from `HermesLinks`, so a row decided from any other values drew nothing. The fix resolves each row's URL from the same values; these pin that what is decided is what is drawn, with injected links that `HermesLinks` does not carry.
///
/// `ApprovalActivityIntents.swift`: the deep link's fallback force-unwrapped a parsed literal in code the widget process also runs. Nothing observable changes, so there is no red; these pin where the fallback lands.
@MainActor
final class LinkResolutionTests: XCTestCase {

    private let repo = URL(string: "https://github.com/example/repo")!
    private let policy = URL(string: "https://example.invalid/privacy")!
    private let support = URL(string: "mailto:support@example.invalid")!

    // MARK: First run

    func testEveryFirstRunRowIsDrawnWithTheURLThatDecidedIt() {
        let links = FirstRunLinkRow.visibleLinks(github: repo, privacyPolicy: policy, support: support)
        XCTAssertEqual(links, [
            FirstRunLink(row: .github, url: repo),
            FirstRunLink(row: .privacyPolicy, url: policy),
            FirstRunLink(row: .support, url: support),
        ], "the shipped `HermesLinks` has no privacy or support URL, so a re-read would have drawn two empty slots here")
    }

    func testAnAbsentFirstRunLinkIsNotDrawn() {
        let links = FirstRunLinkRow.visibleLinks(github: nil, privacyPolicy: policy, support: nil)
        XCTAssertEqual(links, [FirstRunLink(row: .privacyPolicy, url: policy)])
    }

    func testVisibleRowsIsTheDrawnLinksRows() {
        XCTAssertEqual(
            FirstRunLinkRow.visibleRows(github: repo, privacyPolicy: nil, support: support),
            FirstRunLinkRow.visibleLinks(github: repo, privacyPolicy: nil, support: support).map(\.row)
        )
        XCTAssertEqual(FirstRunLinkRow.visibleRows(), FirstRunLinkRow.visibleLinks().map(\.row))
    }

    // MARK: About

    func testEveryAboutLinkRowResolvesFromTheLinksThatDecidedIt() {
        let links = AboutLinks(github: repo, privacyPolicy: policy, support: support)
        let entries = AboutSupportEntry.entries(links)
        XCTAssertEqual(entries, [.github(repo), .link(.privacyPolicy), .link(.support), .diagnostics, .advancedToggle])
        XCTAssertEqual(entries.map { $0.destination(in: links) }, [repo, policy, support, nil, nil],
                       "a link row resolved its URL from somewhere other than the links that put it on screen")
    }

    func testTheShippedLinksAreHermesLinks() {
        XCTAssertEqual(AboutLinks.shipped, AboutLinks(github: HermesLinks.github, privacyPolicy: HermesLinks.privacyPolicy, support: HermesLinks.support))
        XCTAssertEqual(AboutSupportEntry.entries(.shipped), AboutSupportEntry.entries())
    }

    // MARK: The activity deep link

    func testTheFallbackLandsOnHome() {
        XCTAssertEqual(HermesActivityLink.home.absoluteString, "hermes://chat")
        XCTAssertNil(HermesActivityLink.sessionKey(from: HermesActivityLink.home), "the fallback must read as no chat, which RootView takes Home")
        XCTAssertNil(HermesActivityLink.sessionKey(from: URL(fileURLWithPath: "/")), "the unreachable arm reads as no chat too")
    }

    func testAChatLinkRoundTrips() {
        for key in ["rt-1", "20260824_200258_8e608f", "a b", "é"] {
            XCTAssertEqual(HermesActivityLink.sessionKey(from: HermesActivityLink.chat(sessionKey: key)), key, key)
        }
        XCTAssertNil(HermesActivityLink.sessionKey(from: HermesActivityLink.chat(sessionKey: "")))
    }
}

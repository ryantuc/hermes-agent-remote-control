import Foundation
import XCTest

@testable import HermesMobile

/// FEAT-031's About screen and BUG-085's export copy.
///
/// Two separate contracts meet here. The Support group's is that it **always
/// exists** — the old one disappeared entirely, because both of its rows were
/// links that had not been supplied yet, so the shipped app had no GitHub,
/// no diagnostics entry point that a person looking for one would find, and an
/// advanced toggle stranded under the Settings root's About header with no
/// header of its own. The export row's is that it never again makes a claim it
/// cannot keep.
///
/// `@MainActor` because `AboutView` is, and `exportExplainer` is one of its
/// statics — the sentence lives next to the row that draws it on purpose.
@MainActor
final class AboutScreenTests: XCTestCase {

    private let policy = URL(string: "https://example.invalid/privacy")!
    private let support = URL(string: "mailto:support@example.invalid")!
    private let repo = URL(string: "https://github.com/example/repo")!

    // MARK: The Support group

    /// The whole point of the regrouping: with nothing hosted at all there are
    /// still rows, because two of them are not links.
    func testTheGroupExistsWithNoHostedLinksAtAll() {
        let entries = AboutSupportEntry.entries(github: nil, privacyPolicy: nil, support: nil)
        XCTAssertEqual(entries, [.diagnostics, .advancedToggle])
    }

    func testGitHubLeadsAndCarriesItsURL() {
        let entries = AboutSupportEntry.entries(github: repo, privacyPolicy: nil, support: nil)
        XCTAssertEqual(entries.first, .github(repo))
    }

    /// Links first, then the two rows that stay put — so the order does not
    /// shuffle under the reader when a policy is finally hosted.
    func testTheOrderIsStableAsLinksArrive() {
        XCTAssertEqual(
            AboutSupportEntry.entries(github: repo, privacyPolicy: policy, support: support),
            [.github(repo), .link(.privacyPolicy), .link(.support), .diagnostics, .advancedToggle]
        )
        XCTAssertEqual(
            AboutSupportEntry.entries(github: repo, privacyPolicy: nil, support: support),
            [.github(repo), .link(.support), .diagnostics, .advancedToggle]
        )
    }

    /// `AboutLinkRow`'s own contract is untouched: an unset link still draws no
    /// row, which is what `AboutLinkRowTests` asserts and what App Review
    /// 5.1.1(i) and 1.5 are waiting on.
    func testAnUnsuppliedLinkStillDrawsNothing() {
        let entries = AboutSupportEntry.entries(github: repo, privacyPolicy: nil, support: nil)
        XCTAssertFalse(entries.contains(.link(.privacyPolicy)))
        XCTAssertFalse(entries.contains(.link(.support)))
    }

    /// If this is ever nil the group loses its lead row and the shipped build
    /// has no route to the source at all.
    func testTheShippedBuildHasAGitHubLink() {
        XCTAssertNotNil(HermesLinks.github)
        XCTAssertEqual(HermesLinks.github?.scheme, "https")
        XCTAssertEqual(HermesLinks.github?.host, "github.com")
    }

    /// The advanced gate moved off the Settings root and has to be somewhere.
    func testTheAdvancedGateIsOnThisScreen() {
        XCTAssertTrue(AboutSupportEntry.entries().contains(.advancedToggle))
        XCTAssertTrue(AboutSupportEntry.entries().contains(.diagnostics))
    }

    // MARK: BUG-085 — the export row's sentence

    /// The exact sentence that was there, in every state, whatever the
    /// document held. Its absence is the fix.
    func testTheAbsoluteSecretsClaimIsGoneFromEveryState() {
        let claim = "Secrets are not part of the configuration"
        for result in Self.everyExportState {
            XCTAssertFalse(
                AboutView.exportExplainer(result).contains(claim),
                "the export row must not assert something it cannot enforce"
            )
        }
    }

    /// Even the clean case tells the reader to look, because a secret under a
    /// key this app has never heard of cannot be recognised by any pass.
    func testTheCleanStateStillAsksTheReaderToCheck() {
        let clean = ConfigExportRedaction.Result(
            document: .object([:]), redactedKeyCount: 0, redactedValueCount: 0,
            usedFallbackLiteralPass: false
        )
        XCTAssertFalse(clean.didRedactAnything)
        let text = AboutView.exportExplainer(clean)
        XCTAssertTrue(text.lowercased().contains("check it before sharing"))
        XCTAssertTrue(text.lowercased().contains("no known secret fields"))
    }

    func testTheRedactedStateNamesWhatWentAndAdmitsItIsPartial() {
        let redacted = ConfigExportRedaction.Result(
            document: .object([:]), redactedKeyCount: 2, redactedValueCount: 3,
            usedFallbackLiteralPass: false
        )
        let text = AboutView.exportExplainer(redacted)
        XCTAssertTrue(text.contains(ConfigExportRedaction.placeholder))
        XCTAssertTrue(text.lowercased().contains("best-effort"))
        XCTAssertFalse(text.lowercased().contains("repeating a secret"))
    }

    func testTheResidualPassAddsItsOwnSentence() {
        let residual = ConfigExportRedaction.Result(
            document: .object([:]), redactedKeyCount: 1, redactedValueCount: 2,
            usedFallbackLiteralPass: true
        )
        XCTAssertTrue(
            AboutView.exportExplainer(residual).lowercased().contains("repeating a secret")
        )
    }

    private static let everyExportState: [ConfigExportRedaction.Result] = [
        .init(document: .object([:]), redactedKeyCount: 0, redactedValueCount: 0, usedFallbackLiteralPass: false),
        .init(document: .object([:]), redactedKeyCount: 1, redactedValueCount: 1, usedFallbackLiteralPass: false),
        .init(document: .object([:]), redactedKeyCount: 1, redactedValueCount: 2, usedFallbackLiteralPass: true),
    ]
}

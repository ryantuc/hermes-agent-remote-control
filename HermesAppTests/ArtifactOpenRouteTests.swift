import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-176. Tapping an Artifacts tile whose value is an inline `data:image/…` URL handed that URL to `SFSafariViewController`, which Apple documents as http and https only and which raises on any other scheme. The scrape produces such records (`ArtifactScrape.looksLikeArtifact` and `kind(of:)` accept `data:image/`), so the in-chat generated image was one tap from a crash. Quick Look already decodes a `data:` URL locally (`MediaFileFetch.data(for:gateway:)`), so that is where it goes.
@MainActor
final class ArtifactOpenRouteTests: XCTestCase {
    private let dataImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func testAnInlineDataImageOpensInQuickLookNotTheBrowser() {
        XCTAssertEqual(ArtifactsView.destination(kind: .image, value: dataImage), .quickLook(dataImage),
                       "a data: URL reached SFSafariViewController, which accepts only http and https and raises on anything else")
    }

    func testEveryDataValueStaysOutOfTheBrowserWhateverItsKind() {
        for kind in ArtifactScrape.Kind.allCases {
            XCTAssertNotEqual(ArtifactsView.destination(kind: kind, value: dataImage), .browser, "\(kind)")
        }
    }

    /// The browser path's own guard, for whatever `resolveURL` returns: a gateway image resolves to a `data:` URL too.
    func testOnlyHTTPAndHTTPSReachTheBrowser() throws {
        XCTAssertTrue(ArtifactsView.isBrowsable(try XCTUnwrap(URL(string: "https://example.com/a"))))
        XCTAssertTrue(ArtifactsView.isBrowsable(try XCTUnwrap(URL(string: "HTTP://example.com/a"))))
        XCTAssertFalse(ArtifactsView.isBrowsable(try XCTUnwrap(URL(string: dataImage))))
        XCTAssertFalse(ArtifactsView.isBrowsable(try XCTUnwrap(URL(string: "file:///tmp/a.png"))))
        XCTAssertFalse(ArtifactsView.isBrowsable(try XCTUnwrap(URL(string: "example.com/a"))))
    }

    func testTheOtherRoutesAreUnchanged() {
        XCTAssertEqual(ArtifactsView.destination(kind: .image, value: "https://example.com/cat.png"), .browser)
        XCTAssertEqual(ArtifactsView.destination(kind: .image, value: "/home/me/out/chart.png"), .quickLook("/home/me/out/chart.png"))
        XCTAssertEqual(ArtifactsView.destination(kind: .file, value: "/home/me/out/report.pdf"), .quickLook("/home/me/out/report.pdf"))
        XCTAssertEqual(ArtifactsView.destination(kind: .link, value: "https://example.com/docs"), .browser)
    }
}

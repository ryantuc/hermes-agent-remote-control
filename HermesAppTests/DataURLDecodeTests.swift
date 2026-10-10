import XCTest

@testable import HermesMobile

/// BUG-146 (`DownsampledImage.swift` `data(fromDataURL:)`) — the decode checked only the `data:image/` prefix and then base64-decoded whatever followed the comma, whether or not the header said `;base64`.
///
/// RFC 2397: `data:[<mediatype>][;base64],<data>`; without `;base64` the payload is percent-encoded octets. So `data:image/png,AAAA` is the four bytes `AAAA`, not the three zero bytes base64 makes of it, and `data:image/svg+xml,%3Csvg%2F%3E` is `<svg/>`, not a decode failure that happened to return nil for the wrong reason.
final class DataURLDecodeTests: XCTestCase {

    func testABase64ImageDataURLDecodesAsBefore() {
        XCTAssertEqual(DownsampledImage.data(fromDataURL: "data:image/png;base64,aGVsbG8="), Data("hello".utf8))
    }

    func testAPayloadWithoutTheBase64FlagIsNotBase64Decoded() {
        XCTAssertEqual(DownsampledImage.data(fromDataURL: "data:image/png,AAAA"), Data("AAAA".utf8),
                       "\"AAAA\" is valid base64 for three zero bytes, so ignoring the header returned the wrong bytes")
    }

    func testAPercentEncodedImageDataURLDecodes() {
        XCTAssertEqual(DownsampledImage.data(fromDataURL: "data:image/svg+xml,%3Csvg%2F%3E"), Data("<svg/>".utf8))
    }

    func testPercentEncodingCarriesBytesThatAreNotText() {
        XCTAssertEqual(DownsampledImage.data(fromDataURL: "data:image/png,%89PNG%0D%0A"), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
                       "percent-encoding is octets, so a payload that is not UTF-8 must still decode")
    }

    func testParametersBeforeTheBase64FlagAreAllowed() {
        XCTAssertEqual(DownsampledImage.data(fromDataURL: "data:image/png;name=chart.png;base64,aGVsbG8="), Data("hello".utf8))
    }

    func testTheSchemeAndFlagAreCaseInsensitive() {
        XCTAssertEqual(DownsampledImage.data(fromDataURL: "DATA:image/PNG;BASE64,aGVsbG8="), Data("hello".utf8))
    }

    func testANonImageDataURLIsStillRefused() {
        XCTAssertNil(DownsampledImage.data(fromDataURL: "data:text/plain;base64,aGVsbG8="))
        XCTAssertNil(DownsampledImage.data(fromDataURL: "data:,hello"), "no media type means text/plain")
    }

    func testMalformedDataURLsAreRefused() {
        XCTAssertNil(DownsampledImage.data(fromDataURL: "data:image/png;base64"), "no comma, no payload")
        XCTAssertNil(DownsampledImage.data(fromDataURL: "data:image/png;base64,***"), "not base64")
        XCTAssertNil(DownsampledImage.data(fromDataURL: "data:image/png,%G0"), "not a percent escape")
        XCTAssertNil(DownsampledImage.data(fromDataURL: "/Users/agent/out/chart.png"), "not a data URL at all")
    }
}

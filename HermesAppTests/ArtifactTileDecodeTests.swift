import UIKit
import XCTest

@testable import HermesMobile

/// BUG-075 leg C — the Artifacts Images grid decoded every tile at full size with `UIImage(data:)`, inside `body`, so a scrolled gallery of camera-sized images held a full bitmap per visible cell (a 12 MP photo is about 48 MB decoded) — exactly the cost `DownsampledImage` exists to prevent in the transcript.
///
/// What is pinned here is the decode itself: a tile's bitmap is no larger than the tile's pixel budget, whatever the source size. Where the decode runs (once per tile, off the main thread, not in `body`) is the view's shape and is not observable from a unit test; the record says how to check it.
final class ArtifactTileDecodeTests: XCTestCase {

    /// A real PNG of the given pixel size, as the `data:` URL the scrape hands the grid.
    private static func pngDataURL(width: Int, height: Int) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        let png = try XCTUnwrap(image.pngData())
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static func pixelSize(_ image: UIImage) -> (width: Int, height: Int) {
        if let cgImage = image.cgImage { return (cgImage.width, cgImage.height) }
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
    }

    func testALargeImageDecodesNoLargerThanTheTileBudget() throws {
        let dataURL = try Self.pngDataURL(width: 2_400, height: 1_800)

        let tile = try XCTUnwrap(ArtifactTile.image(fromDataURL: dataURL), "a valid PNG data URL must decode")
        let size = Self.pixelSize(tile)

        XCTAssertLessThanOrEqual(max(size.width, size.height), DownsampledImage.artifactTileMaxPixelSize,
                                 "the tile decoded to \(size.width)x\(size.height): a full-size bitmap for a 104 pt cell (BUG-075 C)")
        XCTAssertEqual(Double(size.width) / Double(size.height), 4.0 / 3.0, accuracy: 0.02, "downsampling keeps the aspect ratio")
    }

    func testASmallImageIsNotScaledUp() throws {
        let dataURL = try Self.pngDataURL(width: 64, height: 48)

        let tile = try XCTUnwrap(ArtifactTile.image(fromDataURL: dataURL))
        let size = Self.pixelSize(tile)

        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
    }

    func testANonImageDataURLGivesNoTile() {
        XCTAssertNil(ArtifactTile.image(fromDataURL: "data:text/plain;base64,aGVsbG8="))
        XCTAssertNil(ArtifactTile.image(fromDataURL: "data:image/png;base64,not-base64-at-all"))
    }
}

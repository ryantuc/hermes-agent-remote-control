import UIKit
import XCTest

@testable import HermesMobile

/// A fling through the Images grid cancels each tile's `.task`, but a gateway tile has already pulled the whole file by then (kit requests run to completion, BUG-093). The tile checked for cancellation before writing the decoded image to the cache, so the finished work was thrown away and repeated on every pass; and nothing bounded how many tiles held a full payload at once.
final class ArtifactTileLoadTests: XCTestCase {

    private static func pngDataURL() throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return "data:image/png;base64," + (try XCTUnwrap(image.pngData())).base64EncodedString()
    }

    /// How many fetches run at once, and the most there ever were.
    private actor Peak {
        private(set) var now = 0
        private(set) var most = 0
        func enter() { now += 1; most = max(most, now) }
        func leave() { now -= 1 }
    }

    func testATileFetchedBeforeItsTaskWasCancelledIsStillCached() async throws {
        let dataURL = try Self.pngDataURL()
        let key = "tile-cancelled-\(UUID().uuidString)"
        let task = Task {
            await ArtifactTile.cachedThumbnail(key: key, value: "/home/me/out/\(key).png", mediaDataURL: { _ in
                // The fling lands while the bytes are already on their way back.
                withUnsafeCurrentTask { $0?.cancel() }
                return dataURL
            })
        }
        _ = await task.value
        XCTAssertNotNil(ArtifactTile.cache.object(forKey: key as NSString), "the tile was fetched and decoded, then thrown away because its task had been cancelled; the next pass fetches it again")
    }

    func testOnlyAFewTilesLoadAtOnce() async throws {
        let dataURL = try Self.pngDataURL()
        let prefix = "tile-bounded-\(UUID().uuidString)"
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = await ArtifactTile.cachedThumbnail(key: "\(prefix)-\(index)", value: "/home/me/out/\(prefix)-\(index).png", mediaDataURL: { _ in
                        await peak.enter()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await peak.leave()
                        return dataURL
                    })
                }
            }
        }
        let most = await peak.most
        XCTAssertLessThanOrEqual(most, ArtifactTile.maxConcurrentLoads, "\(most) tiles fetched at once; each holds a whole file until it is decoded")
        for index in 0..<12 {
            XCTAssertNotNil(ArtifactTile.cache.object(forKey: "\(prefix)-\(index)" as NSString), "tile \(index) never loaded: the bound must queue loads, not drop them")
        }
    }
}

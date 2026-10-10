import Foundation

/// Encoded image bytes the transcript already holds, keyed by every name a turn may use for them: the filename a pick was queued under, the gateway path `image.attach_bytes` answered with, or the path a reply was resolved from.
/// A photo the user just sent is drawn from here instead of being fetched back from the backend, and a thumbnail that scrolled away is not fetched twice. Bounded by cost, so a run of large photos evicts the oldest rather than growing.
final class MediaByteCache: @unchecked Sendable {
    static let shared = MediaByteCache()

    private let cache = NSCache<NSString, NSData>()

    init(totalCostLimit: Int = 48 * 1024 * 1024) {
        cache.totalCostLimit = totalCostLimit
    }

    func remember(_ data: Data, keys: [String]) {
        for key in keys where !key.isEmpty {
            cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        }
    }

    func data(for key: String) -> Data? {
        cache.object(forKey: key as NSString).map { Data(referencing: $0) }
    }

    func holds(_ key: String) -> Bool {
        cache.object(forKey: key as NSString) != nil
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

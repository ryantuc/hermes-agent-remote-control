import ImageIO
import UIKit

/// ImageIO-backed decode helpers for transcript media: a 12 MP photo is ~48 MB once decoded, so bubbles use ``thumbnail(data:maxPixelSize:)`` and full-size decode belongs only in the media viewer.
enum DownsampledImage {
    /// Pixel budget for the 220 pt transcript thumbnail at 3× (~660 px).
    static let transcriptMaxPixelSize = 660

    /// Downsampled decode that materialises only the thumbnail bitmap, never the full image.
    static func thumbnail(data: Data, maxPixelSize: Int = transcriptMaxPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    static func full(data: Data) -> UIImage? {
        UIImage(data: data)
    }

    /// Pull the base64 payload out of a `data:image/…;base64,…` URL string.
    static func data(fromDataURL string: String) -> Data? {
        guard string.hasPrefix("data:image/"),
              let comma = string.firstIndex(of: ",")
        else { return nil }
        return Data(base64Encoded: String(string[string.index(after: comma)...]))
    }
}

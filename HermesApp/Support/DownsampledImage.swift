import ImageIO
import UIKit

/// ImageIO-backed decode helpers for transcript media: a 12 MP photo is ~48 MB once decoded, so bubbles use ``thumbnail(data:maxPixelSize:)`` and full-size decode belongs only in the media viewer.
enum DownsampledImage {
    /// Pixel budget for the 220 pt transcript thumbnail at 3× (~660 px).
    static let transcriptMaxPixelSize = 660

    /// Pixel budget for an Artifacts grid tile: a third of a phone's width is about 130 pt, 390 px at 3×, and the tile fills by cropping the long side, so 480 keeps a 4:3 image's short side at the tile's size.
    static let artifactTileMaxPixelSize = 480

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

    /// The bytes of a `data:image/…` URL; nil for any other media type, so a caller cannot hand a PDF to ImageIO by accident.
    static func data(fromDataURL string: String) -> Data? {
        guard let parsed = DataURL(string), parsed.mediaType.hasPrefix("image/") else { return nil }
        return parsed.data
    }
}

/// An RFC 2397 `data:` URL taken apart: `data:[<media type>][;base64],<data>`.
/// The `;base64` flag decides the decode. Without it the payload is percent-encoded octets, and base64-decoding it anyway turns `data:image/png,AAAA` into three zero bytes (BUG-146).
struct DataURL: Equatable {
    /// Lowercased with its parameters dropped; `text/plain`, RFC 2397's default, when the header names none.
    let mediaType: String
    let data: Data

    init?(_ string: String) {
        guard let header = Self.header(of: string) else { return nil }
        let payload = string[header.payloadStart...]

        let bytes: Data?
        if header.isBase64 {
            // A base64 payload may itself arrive percent-escaped (`%2B`, `%2F`, `%3D`) when the URL went through an encoder.
            bytes = Data(base64Encoded: String(payload)) ?? Self.percentDecoded(payload).flatMap { Data(base64Encoded: $0) }
        } else {
            bytes = Self.percentDecoded(payload)
        }
        guard let bytes else { return nil }
        mediaType = header.mediaType
        data = bytes
    }

    /// The media type alone, read from the header without decoding a payload that may be megabytes long.
    static func mediaType(of string: String) -> String? {
        header(of: string)?.mediaType
    }

    private static func header(of string: String) -> (mediaType: String, isBase64: Bool, payloadStart: String.Index)? {
        let utf8 = string.utf8
        guard utf8.prefix(5).elementsEqual("data:".utf8, by: { Self.lowercased($0) == $1 }),
              let comma = string.firstIndex(of: ",")
        else { return nil }

        var parameters = string[utf8.index(utf8.startIndex, offsetBy: 5)..<comma]
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let isBase64 = parameters.last?.lowercased() == "base64"
        if isBase64 { parameters.removeLast() }
        let declared = parameters.first?.lowercased() ?? ""
        return (declared.isEmpty ? "text/plain" : declared, isBase64, string.index(after: comma))
    }

    /// `%XX` escapes to octets, every other byte as itself; nil on a malformed escape. Octets, not a `String`, because a percent-encoded image is not UTF-8.
    private static func percentDecoded(_ payload: Substring) -> Data? {
        var out = Data()
        out.reserveCapacity(payload.utf8.count)
        var bytes = payload.utf8.makeIterator()
        while let byte = bytes.next() {
            guard byte == UInt8(ascii: "%") else {
                out.append(byte)
                continue
            }
            guard let high = bytes.next().flatMap(hexValue), let low = bytes.next().flatMap(hexValue) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }
}

#if DEBUG
import AVFoundation
import CoreGraphics
import Foundation
import HermesServeKit
import UIKit

/// The screenshot harness's media conversation (`-hermesScreenshotRoute media-showcase`): a user turn exactly as the session store persists an attached photo, a reply announcing a clip, and a reply announcing a container the phone does not play. No backend: the photo's bytes are placed in `MediaByteCache` under the gateway path the row names, and a short movie is written into the video cache under the clip's path, so both draw through the same code a live session uses.
enum MediaShowcase {
    static let uploadPath = #"C:\Users\you\AppData\Local\hermes\images\upload_20261004_001751_1.jpg"#
    static let videoPath = #"C:\Users\you\Downloads\bulldog-wake-up.mp4"#
    static let unplayablePath = #"C:\Users\you\Downloads\bulldog-wake-up-source.mkv"#

    /// The persisted user row, verbatim in shape: caption, `@image:` line, the store's `[screenshot]` stand-in.
    static let userRowText = "What this\n@image:\(uploadPath)\n[screenshot]"

    static func page() -> TranscriptPage {
        let start: Double = 1_791_091_071
        var rows: [TranscriptMessage] = []
        func push(_ id: Int, _ role: String, _ content: String) {
            rows.append(TranscriptMessage(json: .object([
                "id": .number(Double(id)),
                "role": .string(role),
                "content": .string(content),
                "timestamp": .number(start + Double(id) * 40),
            ])))
        }
        push(1, "user", userRowText)
        push(2, "assistant", "A French bulldog — fawn coat, short pushed-in snout, and those heavy muzzle wrinkles — lying on a light grey plush blanket. One eye is half open, so it looks like it's giving you a sleepy side-eye rather than actually being awake.")
        push(3, "user", "Now animate that image")
        push(4, "assistant", "Here is the clip, two seconds of the dog waking up.\nMEDIA:\(videoPath)\nThe uncompressed capture is beside it for editing:\nMEDIA:\(unplayablePath)")
        // The photo again at the tail, so a bottom-anchored screenshot shows the user's thumbnail beside the poster.
        push(5, "user", "Same dog?\n@image:\(uploadPath)\n[screenshot]")
        push(6, "assistant", "Same dog: the fawn coat and the half-open eye match the first photo.")
        return TranscriptPage(sessionID: "", messages: rows)
    }

    /// Put the fixture's bytes where the transcript will look for them.
    static func prime() async {
        MediaByteCache.shared.remember(photo(), keys: [uploadPath])
        let file = VideoMedia.cacheURL(for: videoPath)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? await makeMovie(to: file)
        }
    }

    /// A drawn stand-in for the photo: a blanket-grey ground with a fawn shape on it.
    static func photo(size: CGSize = CGSize(width: 960, height: 720)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.78, green: 0.80, blue: 0.83, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.76, green: 0.60, blue: 0.42, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.18, y: size.height * 0.3, width: size.width * 0.64, height: size.height * 0.46)).fill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.58, y: size.height * 0.12, width: size.width * 0.3, height: size.height * 0.36)).fill()
            UIColor(white: 0.15, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.66, y: size.height * 0.26, width: size.width * 0.04, height: size.height * 0.05)).fill()
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    /// A short H.264 movie, drawn frame by frame: the same ground, the fawn shape rising.
    static func makeMovie(to url: URL, seconds: Double = 2, fps: Int32 = 12, size: CGSize = CGSize(width: 640, height: 360)) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                draw(frame: frame, of: frames, in: context, size: size)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func draw(frame: Int, of frames: Int, in context: CGContext, size: CGSize) {
        let progress = CGFloat(frame) / CGFloat(max(frames - 1, 1))
        context.setFillColor(CGColor(red: 0.78, green: 0.80, blue: 0.83, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0.76, green: 0.60, blue: 0.42, alpha: 1))
        let lift = size.height * 0.12 * progress
        context.fillEllipse(in: CGRect(x: size.width * 0.18, y: size.height * 0.24 - lift, width: size.width * 0.64, height: size.height * 0.46))
        context.fillEllipse(in: CGRect(x: size.width * 0.58, y: size.height * 0.52 - lift, width: size.width * 0.3, height: size.height * 0.36))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        let eye = size.height * (0.05 + 0.04 * progress)
        context.fillEllipse(in: CGRect(x: size.width * 0.66, y: size.height * 0.66 - lift, width: size.width * 0.04, height: eye))
    }
}
#endif

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import HermesServeKit

/// **BUG-110 leg 1 and BUG-077.** `AttachmentAPI` had no test of any kind, so a change to what it puts on the wire, or to the six-format gate behind every picked photo, could not turn anything red.
///
/// The wire half pins each method to the params the backend declares. Params models there are `extra="forbid"` (`tui_gateway/contracts/base.py:16-35`), so one undeclared key turns every upload into error 4000. The declared sets are restated from `tui_gateway/contracts/prompt_voice.py:124-200` and `common.py:227-229` on current upstream.
///
/// The BUG-077 half pins what a picked image is turned into before it is queued. The live gateway's `image.attach_bytes` takes the filename's extension as the format (`tui_gateway/prompt_attachments.py:64-71`) and refuses any extension outside `cli._IMAGE_EXTENSIONS` with 4016 (`methods_prompt.py:788-816`, set at `hermes_cli/cli_terminal_input.py:33-36`, which has no `.heic`). So a default-settings iPhone photo cannot go as an image under its own name; it has to leave the phone as a format the gateway takes.
final class AttachmentAPITests: XCTestCase {

    /// The backend's declared params per method (`SessionParams` contributes `session_id` and `profile`).
    private static let declared: [String: Set<String>] = [
        "image.attach_bytes": ["session_id", "profile", "content_base64", "data", "filename", "ext"],
        "file.attach": ["session_id", "profile", "path", "data_url", "name"],
        "image.detach": ["session_id", "profile", "path"],
    ]

    private func assertOnlyDeclaredKeys(
        _ params: JSONValue?,
        for method: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sent = Set(params?.objectValue?.keys.map { $0 } ?? [])
        let undeclared = sent.subtracting(Self.declared[method] ?? [])
        XCTAssertTrue(undeclared.isEmpty, "\(method) sent undeclared params \(undeclared.sorted()); the backend answers 4000", file: file, line: line)
    }

    // MARK: - image.attach_bytes

    func testAttachImageBytesSendsRawBase64UnderTheDeclaredKeysAndDecodesTheReply() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "image.attach_bytes": [.object([
                "attached": .bool(true),
                "path": .string("/home/h/.hermes/images/upload_1.jpg"),
                "name": .string("upload_1.jpg"),
                "count": .number(2),
                "text": .string("[User attached image: upload_1.jpg]"),
            ])],
        ])
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

        let result = try await AttachmentAPI(client: client)
            .attachImageBytes(sessionID: "s1", data: bytes, filename: "photo-1.jpg")

        let params = await socket.sentParams("image.attach_bytes")
        XCTAssertEqual(params?["session_id"]?.stringValue, "s1")
        XCTAssertEqual(params?["content_base64"]?.stringValue, bytes.base64EncodedString(), "raw base64, no data: prefix")
        XCTAssertEqual(params?["filename"]?.stringValue, "photo-1.jpg", "the gateway reads the format off this name")
        assertOnlyDeclaredKeys(params, for: "image.attach_bytes")
        XCTAssertEqual(result, ImageAttachResult(
            attached: true,
            path: "/home/h/.hermes/images/upload_1.jpg",
            name: "upload_1.jpg",
            count: 2,
            text: "[User attached image: upload_1.jpg]"
        ))
    }

    func testAnEmptyImageReplyFallsBackToTheNameItWasSentUnder() async throws {
        let (client, _) = try await ScriptedGateway.connected(replies: ["image.attach_bytes": [.object([:])]])

        let result = try await AttachmentAPI(client: client)
            .attachImageBytes(sessionID: "s1", data: Data([1]), filename: "photo-2.png")

        XCTAssertFalse(result.attached)
        XCTAssertEqual(result.name, "photo-2.png")
        XCTAssertEqual(result.count, 0)
    }

    func testAnImageOverTheBackendCapIsRefusedBeforeAnythingIsSent() async throws {
        let (client, socket) = try await ScriptedGateway.connected()
        let oversized = Data(count: AttachmentAPI.imageByteLimit + 1)

        do {
            _ = try await AttachmentAPI(client: client)
                .attachImageBytes(sessionID: "s1", data: oversized, filename: "huge.png")
            XCTFail("an image over 25 MB must be refused on the phone, not by error 4018 after the upload")
        } catch HermesError.attachmentTooLarge(let bytes, let limit) {
            XCTAssertEqual(bytes, AttachmentAPI.imageByteLimit + 1)
            XCTAssertEqual(limit, 25 * 1024 * 1024, "the backend's _ATTACH_BYTES_MAX_BYTES")
        }
        let sent = await socket.sentCount("image.attach_bytes")
        XCTAssertEqual(sent, 0)
    }

    // MARK: - file.attach

    func testAttachFileSendsAFullDataURLUnderTheDeclaredKeysAndDecodesTheReference() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "file.attach": [.object([
                "attached": .bool(true),
                "name": .string("notes.pdf"),
                "path": .string("/home/h/.hermes/attachments/notes.pdf"),
                "ref_path": .string("attachments/notes.pdf"),
                "ref_text": .string("@file:attachments/notes.pdf"),
                "uploaded": .bool(true),
            ])],
        ])
        let bytes = Data("%PDF-1.7".utf8)

        let result = try await AttachmentAPI(client: client)
            .attachFile(sessionID: "s1", data: bytes, filename: "notes.pdf", mimeType: "application/pdf")

        let params = await socket.sentParams("file.attach")
        XCTAssertEqual(params?["session_id"]?.stringValue, "s1")
        XCTAssertEqual(params?["name"]?.stringValue, "notes.pdf")
        XCTAssertEqual(
            params?["data_url"]?.stringValue,
            "data:application/pdf;base64,\(bytes.base64EncodedString())",
            "file.attach wants the whole data URL, unlike image.attach_bytes"
        )
        assertOnlyDeclaredKeys(params, for: "file.attach")
        XCTAssertEqual(result, FileAttachResult(
            attached: true,
            name: "notes.pdf",
            path: "/home/h/.hermes/attachments/notes.pdf",
            refText: "@file:attachments/notes.pdf",
            uploaded: true
        ))
    }

    // MARK: - image.detach

    func testDetachImageSendsThePathAndReturnsTheNewCount() async throws {
        let (client, socket) = try await ScriptedGateway.connected(replies: [
            "image.detach": [.object(["detached": .bool(true), "count": .number(1)])],
        ])

        let count = try await AttachmentAPI(client: client)
            .detachImage(sessionID: "s1", path: "/home/h/.hermes/images/upload_1.jpg")

        let params = await socket.sentParams("image.detach")
        XCTAssertEqual(params?["path"]?.stringValue, "/home/h/.hermes/images/upload_1.jpg")
        assertOnlyDeclaredKeys(params, for: "image.detach")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Routing

    func testRoutingSendsTheSixGatewayFormatsAsImagesAndEverythingElseAsAFile() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "bmp", "PNG", "JPG"] {
            XCTAssertTrue(AttachmentAPI.isAttachableAsImage(filename: "a.\(ext)", mimeType: "image/x"), ext)
        }
        XCTAssertTrue(AttachmentAPI.isAttachableAsImage(filename: "noextension", mimeType: "image/png"), "no extension: the gateway sniffs")
        XCTAssertFalse(AttachmentAPI.isAttachableAsImage(filename: "photo.heic", mimeType: "image/heic"), "an unconverted HEIC is still a file; preparedForUpload is what keeps one from arriving here")
        XCTAssertFalse(AttachmentAPI.isAttachableAsImage(filename: "notes.pdf", mimeType: "application/pdf"))
        XCTAssertFalse(AttachmentAPI.isAttachableAsImage(filename: "fake.png", mimeType: "application/octet-stream"), "only a declared image is routed as one")
    }

    // MARK: - Pick-time conversion (BUG-077)

    func testAHEICPhotoLeavesThePhoneAsAJPEGImage() throws {
        let heic = try Self.heicFixture()
        XCTAssertEqual(Self.sniffedType(heic), UTType.heic.identifier, "precondition: the fixture is a real HEIC")
        XCTAssertEqual(Self.hasAlpha(heic), false, "precondition: opaque, like a camera photo")

        let prepared = AttachmentAPI.preparedForUpload(
            AttachmentPayload(data: heic, filename: "photo-1727900000-42.heic", mimeType: "image/heic")
        )

        XCTAssertEqual(prepared.filename, "photo-1727900000-42.jpg")
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(Self.sniffedType(prepared.data), UTType.jpeg.identifier, "the bytes are JPEG, not a renamed HEIC")
        XCTAssertTrue(
            AttachmentAPI.isAttachableAsImage(filename: prepared.filename, mimeType: prepared.mimeType),
            "a default-format iPhone photo must ride image.attach_bytes so vision sees it, not file.attach as an @file: stub"
        )
        XCTAssertEqual(Self.pixelSize(prepared.data)?.width, 16, "no resampling")
        XCTAssertEqual(Self.pixelSize(prepared.data)?.height, 12)
    }

    func testAnUnlistedFormatKeepsItsOrientationAsTheJPEGPickWould() throws {
        let tiff = try Self.encoded(.tiff, alpha: false, orientation: 6)
        XCTAssertEqual(Self.hasAlpha(tiff), false, "precondition: an opaque source")

        let prepared = AttachmentAPI.preparedForUpload(
            AttachmentPayload(data: tiff, filename: "scan.tiff", mimeType: "image/tiff")
        )

        XCTAssertEqual(prepared.filename, "scan.jpg")
        XCTAssertEqual(Self.sniffedType(prepared.data), UTType.jpeg.identifier)
        XCTAssertEqual(Self.orientation(prepared.data), 6, "a portrait shot must not arrive on its side")
    }

    func testAnUnlistedFormatWithTransparencyLeavesAsPNG() throws {
        let tiff = try Self.encoded(.tiff, alpha: true)
        XCTAssertEqual(Self.hasAlpha(tiff), true, "precondition: the source carries alpha")

        let prepared = AttachmentAPI.preparedForUpload(
            AttachmentPayload(data: tiff, filename: "cutout.tif", mimeType: "image/tiff")
        )

        XCTAssertEqual(prepared.filename, "cutout.png", "JPEG has no alpha; transparent pixels would turn black")
        XCTAssertEqual(prepared.mimeType, "image/png")
        XCTAssertEqual(Self.sniffedType(prepared.data), UTType.png.identifier)
    }

    func testGatewayFormatBytesUnderAnUnlistedNameAreRenamedNotReencoded() throws {
        let png = try Self.encoded(.png, alpha: false)

        let prepared = AttachmentAPI.preparedForUpload(
            AttachmentPayload(data: png, filename: "photo-7.heic", mimeType: "image/heic")
        )

        XCTAssertEqual(prepared.filename, "photo-7.png")
        XCTAssertEqual(prepared.mimeType, "image/png")
        XCTAssertEqual(prepared.data, png, "already a format the gateway takes: the bytes go as they are")
    }

    func testAGatewayFormatIsSentByteForByte() throws {
        let png = try Self.encoded(.png, alpha: true)
        let payload = AttachmentPayload(data: png, filename: "shot.png", mimeType: "image/png")

        XCTAssertEqual(AttachmentAPI.preparedForUpload(payload), payload)
    }

    func testNonImagesAndUndecodableImagesAreLeftAlone() {
        let pdf = AttachmentPayload(data: Data("%PDF-1.7".utf8), filename: "notes.pdf", mimeType: "application/pdf")
        XCTAssertEqual(AttachmentAPI.preparedForUpload(pdf), pdf)

        let movie = AttachmentPayload(data: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]), filename: "video-1.mov", mimeType: "video/quicktime")
        XCTAssertEqual(AttachmentAPI.preparedForUpload(movie), movie)

        let junk = AttachmentPayload(data: Data([1, 2, 3, 4]), filename: "broken.heic", mimeType: "image/heic")
        XCTAssertEqual(AttachmentAPI.preparedForUpload(junk), junk, "nothing to decode: it keeps today's route as a file rather than vanishing")
    }

    // MARK: - Image helpers

    private struct FixtureMissing: Error {}

    static func heicFixture() throws -> Data {
        guard let base64 = try Fixtures.json("image-heic-16x12")["base64"]?.stringValue,
              let data = Data(base64Encoded: base64)
        else { throw FixtureMissing() }
        return data
    }

    static func encoded(_ type: UTType, alpha: Bool, orientation: Int? = nil) throws -> Data {
        let width = 8, height = 6
        let bitmapInfo = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        ) else { throw FixtureMissing() }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw FixtureMissing() }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureMissing() }
        return output as Data
    }

    static func sniffedType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    private static func properties(_ data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let properties = properties(data),
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    static func orientation(_ data: Data) -> Int? {
        properties(data)?[kCGImagePropertyOrientation] as? Int
    }

    /// ImageIO leaves the key out for an opaque image rather than writing false (observed on the simulator), so absent reads as opaque, as `preparedForUpload` reads it; nil only when the bytes cannot be read.
    static func hasAlpha(_ data: Data) -> Bool? {
        guard let properties = properties(data) else { return nil }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }
}

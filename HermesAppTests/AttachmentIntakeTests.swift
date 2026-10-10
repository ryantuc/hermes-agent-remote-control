import HermesServeKit
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HermesMobile

/// **Attachment intake.** What the `+` sheet's three arms do with what the user picked, before anything is queued.
///
/// - **BUG-079**: the 64 MB cap was compared only after the whole file was in memory (`ComposerOptionsSheet.swift`, the importer's `Data(contentsOf:)` then `data.count`), so a long video killed the app before the friendly refusal could show. The pin is the order: an oversized file is refused without one read.
/// - **BUG-080**: the importer's `.failure` arm returned with no message, and the camera closed silently when its capture produced no JPEG. Both now land on the sheet's error line; a cancel still says nothing.
/// - **BUG-077**: a photo in a format the gateway refuses under its own name (HEIC from a default iPhone, here TIFF, which the simulator can always encode) is converted before it is queued, so it routes as an image. `AttachmentAPITests` pins the HEIC case itself against a real Apple-encoded file.
/// - **BUG-146** (`CameraPicker.swift`, the `.photoLibrary` fallback): a library pick is not named as a camera shot.
@MainActor
final class AttachmentIntakeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentIntakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func file(_ name: String, data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func file(_ name: String, bytes: Int) throws -> URL {
        try file(name, data: Data(count: bytes))
    }

    // MARK: - BUG-079, the cap before the load

    func testAFileOverTheCapIsRefusedBeforeAnyOfItIsRead() throws {
        let url = try file("clip.mov", bytes: 2048)
        var reads = 0

        let result = AttachmentPick.readCapped(url, limit: 1024) { url in
            reads += 1
            return try Data(contentsOf: url)
        }

        XCTAssertEqual(result, .tooLarge(bytes: 2048))
        XCTAssertEqual(reads, 0, "the whole file was pulled into memory to learn it was too big; a 4K video kills the app here")
    }

    func testTheImporterRefusesAnOversizedFileWithoutReadingIt() throws {
        let url = try file("long-4k.mov", bytes: 4096)
        var reads = 0

        let outcome = AttachmentPick.importFiles(.success([url]), limit: 1024) { url in
            reads += 1
            return try Data(contentsOf: url)
        }

        XCTAssertTrue(outcome.payloads.isEmpty)
        XCTAssertEqual(outcome.failure, AttachmentPick.tooLargeMessage(bytes: 4096, limit: 1024))
        XCTAssertEqual(reads, 0)
    }

    func testAFileUnderTheCapIsReadOnceAndQueuedUnderItsOwnName() throws {
        let url = try file("notes.pdf", data: Data("%PDF-1.7".utf8))
        var reads = 0

        let outcome = AttachmentPick.importFiles(.success([url]), limit: 1024) { url in
            reads += 1
            return try Data(contentsOf: url)
        }

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(outcome.payloads.map(\.filename), ["notes.pdf"])
        XCTAssertEqual(outcome.payloads.first?.mimeType, "application/pdf")
    }

    func testBytesThatOutgrowTheReportedSizeAreStillHeldToTheCap() throws {
        let url = try file("growing.log", bytes: 10)

        let result = AttachmentPick.readCapped(url, limit: 1024) { _ in Data(count: 2048) }

        XCTAssertEqual(result, .tooLarge(bytes: 2048), "a size the file system under-reports must not slip past the cap")
    }

    // MARK: - BUG-080, failures say so

    func testAnImporterFailureIsShownNotSwallowed() {
        let outcome = AttachmentPick.importFiles(.failure(CocoaError(.fileReadNoPermission)), limit: 1024)

        XCTAssertTrue(outcome.payloads.isEmpty)
        XCTAssertEqual(
            outcome.failure,
            AttachmentPick.failedToLoadMessage,
            "the importer's failure arm returned with nothing on the sheet: indistinguishable from a cancel"
        )
    }

    func testACancelledImportSaysNothing() {
        let outcome = AttachmentPick.importFiles(.failure(CocoaError(.userCancelled)), limit: 1024)

        XCTAssertNil(outcome.failure, "backing out of Files is not an error")
    }

    func testACameraCaptureThatProducesNoImageIsShownNotSwallowed() {
        var captured: [String] = []
        var failures: [String] = []
        var finished = 0
        let coordinator = CameraPicker.Coordinator(
            onCapture: { _, name in captured.append(name) },
            onFailure: { failures.append($0) },
            onFinish: { finished += 1 }
        )

        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [:])

        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(failures.count, 1, "the camera closed and the shot was gone with no word on the sheet")
        XCTAssertFalse(failures.first?.isEmpty ?? true)
        XCTAssertEqual(finished, 1, "the camera still closes")
    }

    func testACameraCaptureThatEncodesIsDeliveredAndNothingIsReported() {
        var captured: [Data] = []
        var failures: [String] = []
        let coordinator = CameraPicker.Coordinator(
            onCapture: { data, _ in captured.append(data) },
            onFailure: { failures.append($0) },
            onFinish: {}
        )

        coordinator.imagePickerController(
            UIImagePickerController(),
            didFinishPickingMediaWithInfo: [.originalImage: Self.opaqueImage()]
        )

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first.flatMap { Self.sniffedType($0) }, UTType.jpeg.identifier)
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - BUG-146, the library fallback's name

    func testALibraryPickIsNotNamedAsACameraShot() {
        var names: [String] = []
        let coordinator = CameraPicker.Coordinator(
            onCapture: { _, name in names.append(name) },
            onFailure: { _ in },
            onFinish: {}
        )
        let picker = UIImagePickerController()
        XCTAssertEqual(picker.sourceType, .photoLibrary, "precondition: the fallback CameraPicker takes when there is no camera")

        coordinator.imagePickerController(picker, didFinishPickingMediaWithInfo: [.originalImage: Self.opaqueImage()])

        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names.first?.hasPrefix("photo-") ?? false, "a library pick was sent as \(names.first ?? "nothing")")
        XCTAssertTrue(names.first?.hasSuffix(".jpg") ?? false)
    }

    func testACameraShotIsNamedAsOne() {
        XCTAssertEqual(
            CameraPicker.captureName(sourceType: .camera, at: Date(timeIntervalSince1970: 1_727_900_000)),
            "camera-1727900000.jpg"
        )
    }

    // MARK: - BUG-077, converted at pick time

    func testAPhotoInAFormatTheGatewayRefusesIsQueuedAsAnImage() throws {
        let tiff = try Self.tiff()
        XCTAssertEqual(Self.hasAlpha(tiff), false, "precondition: an opaque source, so JPEG is the expected target")

        let payload = AttachmentPick.photoPayload(data: tiff, contentType: .tiff, baseName: "photo-1727900000-42")

        XCTAssertEqual(payload.filename, "photo-1727900000-42.jpg")
        XCTAssertEqual(payload.mimeType, "image/jpeg")
        XCTAssertEqual(Self.sniffedType(payload.data), UTType.jpeg.identifier)
        XCTAssertTrue(
            AttachmentAPI.isAttachableAsImage(filename: payload.filename, mimeType: payload.mimeType),
            "ChatModel.addAttachment routes on exactly this call; false means file.attach and an @file: stub the model cannot see"
        )
    }

    func testAFileInAFormatTheGatewayRefusesIsQueuedAsAnImage() throws {
        let url = try file("scan.tiff", data: try Self.tiff())

        let outcome = AttachmentPick.importFiles(.success([url]), limit: 1 << 20)

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.payloads.map(\.filename), ["scan.jpg"])
        XCTAssertEqual(outcome.payloads.first?.mimeType, "image/jpeg")
    }

    func testAPickedVideoIsNotConverted() {
        let bytes = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70])

        let payload = AttachmentPick.photoPayload(data: bytes, contentType: .quickTimeMovie, baseName: "video-1727900000-7")

        XCTAssertEqual(payload, AttachmentPayload(data: bytes, filename: "video-1727900000-7.mov", mimeType: "video/quicktime"))
    }

    // MARK: - Helpers

    private struct EncodeFailed: Error {}

    static func opaqueImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
    }

    static func tiff() throws -> Data {
        guard let image = opaqueImage().cgImage else { throw EncodeFailed() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.tiff.identifier as CFString, 1, nil
        ) else { throw EncodeFailed() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodeFailed() }
        return output as Data
    }

    static func sniffedType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    /// ImageIO leaves the key out for an opaque image rather than writing false, so absent reads as opaque; nil only when the bytes cannot be read.
    static func hasAlpha(_ data: Data) -> Bool? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }
}

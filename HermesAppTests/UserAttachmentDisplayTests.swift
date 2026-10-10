import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// The photo a user attached, as it comes back from history and as it is drawn right after sending.
///
/// The backend persists the turn as one string, `caption\n@image:<gateway path>\n[screenshot]` (`tui_gateway/session_history.py`, `_build_persist_message_with_image_refs`; the store flattens the image part to the `[screenshot]` line). On a Windows backend the path is `C:\Users\…\images\upload_….jpg`, and the user bubble's chips accepted only `/`, `~` and `@image:` as resolvable, named a chip with `NSString.lastPathComponent` (one separator), and kept the placeholder beside the real ref: the screenshot showed the whole path as a capsule plus a "Screenshot" chip.
@MainActor
final class UserAttachmentDisplayTests: XCTestCase {

    /// A stored row as a reopened chat receives it, content verbatim from a backend's `messages` table.
    private static let storedRow = "What this\n@image:C:\\Users\\you\\AppData\\Local\\hermes\\images\\upload_20261004_001751_1.jpg\n[screenshot]"
    private static let uploadPath = #"C:\Users\you\AppData\Local\hermes\images\upload_20261004_001751_1.jpg"#

    private func page(_ content: String) -> TranscriptPage {
        TranscriptPage(sessionID: "s", messages: [
            TranscriptMessage(json: .object([
                "id": .number(62134), "role": .string("user"), "content": .string(content), "timestamp": .number(1_791_091_071),
            ])),
        ])
    }

    // MARK: History

    func testAReopenedTurnCarriesTheCaptionAndTheGatewayPath() {
        let entries = ChatModel.projectTranscript(page(Self.storedRow))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "What this")
        XCTAssertEqual(entries.first?.imageRefs, [Self.uploadPath, "[screenshot]"])
    }

    /// The backend quotes a path with whitespace in it (`agent/context_references.py:141-149`), which is every Windows account set up with a full name.
    func testAQuotedPathFromAnAccountNameWithASpaceIsUnquoted() {
        let quoted = #"C:\Users\Your Name\AppData\Local\hermes\images\upload_20261004_001751_1.jpg"#
        for quote in ["\"", "'", "`"] {
            let row = "What this\n@image:\(quote)\(quoted)\(quote)\n[screenshot]"
            let entries = ChatModel.projectTranscript(page(row))
            XCTAssertEqual(entries.first?.imageRefs, [quoted, "[screenshot]"], "quoted with \(quote)")
            XCTAssertTrue(AttachmentChips.isResolvablePath(entries.first?.imageRefs.first ?? ""))
            XCTAssertEqual(AttachmentChips.displayName(entries.first?.imageRefs.first ?? ""), "upload_20261004_001751_1.jpg")
        }
    }

    func testTheStoresPlaceholderIsDroppedBesideARealRef() {
        XCTAssertEqual(AttachmentChips.displayRefs([Self.uploadPath, "[screenshot]"]), [Self.uploadPath])
        XCTAssertEqual(AttachmentChips.displayRefs(["[screenshot]", Self.uploadPath, "[screenshot]"]), [Self.uploadPath])
    }

    func testAPlaceholderAloneStaysAndReadsAsAScreenshot() {
        XCTAssertEqual(AttachmentChips.displayRefs(["[screenshot]"]), ["[screenshot]"])
        XCTAssertEqual(AttachmentChips.displayName("[screenshot]"), "Screenshot")
    }

    // MARK: Which chip

    func testAWindowsGatewayPathResolvesOverTheMediaRoute() {
        XCTAssertTrue(AttachmentChips.isResolvablePath(Self.uploadPath), "a drive-letter path is the host's path and the media route serves it")
        XCTAssertTrue(AttachmentChips.isResolvablePath("/home/you/.hermes/images/upload_1.png"))
        XCTAssertTrue(AttachmentChips.isResolvablePath("~/.hermes/images/upload_1.png"))
        XCTAssertTrue(AttachmentChips.isResolvablePath("@image:/tmp/x.png"))
        XCTAssertFalse(AttachmentChips.isResolvablePath("[screenshot]"))
        XCTAssertFalse(AttachmentChips.isResolvablePath("photo-1759-3.jpg"), "a bare filename names nothing the backend can serve")
    }

    func testAChipIsNamedByTheFileNotTheWholePath() {
        XCTAssertEqual(AttachmentChips.displayName(Self.uploadPath), "upload_20261004_001751_1.jpg")
        XCTAssertEqual(AttachmentChips.displayName("@image:/tmp/shots/one.png"), "one.png")
        XCTAssertEqual(AttachmentChips.displayName("photo-1759-3.jpg"), "photo-1759-3.jpg")
    }

    // MARK: The bytes the phone still holds

    func testBytesAreFoundUnderEveryNameTheyWereRememberedBy() {
        let cache = MediaByteCache()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        cache.remember(bytes, keys: ["photo-1.jpg", Self.uploadPath])
        XCTAssertEqual(cache.data(for: "photo-1.jpg"), bytes)
        XCTAssertEqual(cache.data(for: Self.uploadPath), bytes)
        XCTAssertTrue(cache.holds(Self.uploadPath))
        XCTAssertNil(cache.data(for: "photo-2.jpg"))
    }

    func testAPickedPhotoIsHeldUnderItsFilenameBeforeTheUploadAnswers() async {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20261009_170000_media1")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        chat.addAttachment(data: bytes, filename: "photo-1759000000-7.jpg", mimeType: "image/jpeg")
        XCTAssertEqual(MediaByteCache.shared.data(for: "photo-1759000000-7.jpg"), bytes,
                       "the optimistic bubble names the pick by its filename and has nothing to draw unless the bytes are kept under it")
        await harness.tearDown()
    }

    /// After `image.attach_bytes` answers, the live user entry names the gateway's path, the one history will carry back, and the bytes are kept under it, so the thumbnail is drawn from the phone and matches the reopened chat's ref.
    func testASentPhotoIsKeyedByTheGatewayPathAndItsBytesStayOnThePhone() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let chat = harness.chat(storedID: "20261009_170000_media2")
        await chat.open()
        let bound = await waitUntil { chat.runtimeSessionID != nil }
        XCTAssertTrue(bound, "the chat never bound a runtime session id")
        chat.errorMessage = nil

        let gatewayPath = #"C:\Users\you\AppData\Local\hermes\images\upload_20261009_170001_1.jpg"#
        await harness.backend.stub("image.attach_bytes") { _ in
            .object(["attached": .bool(true), "path": .string(gatewayPath), "name": .string("photo-1759000000-8.jpg"), "count": .number(1)])
        }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        chat.addAttachment(data: bytes, filename: "photo-1759000000-8.jpg", mimeType: "image/jpeg")
        chat.draft = "What this"
        chat.sendTapped()

        let submitted = await waitUntil { await harness.backend.callCount("prompt.submit") == 1 }
        XCTAssertTrue(submitted, "the send never reached prompt.submit")
        let keyed = await waitUntil {
            chat.entries.contains { $0.kind == .user && $0.imageRefs == [gatewayPath] }
        }
        XCTAssertTrue(keyed, "the user entry's refs were \(chat.entries.filter { $0.kind == .user }.map(\.imageRefs)); expected the gateway path the upload answered with")
        XCTAssertEqual(MediaByteCache.shared.data(for: gatewayPath), bytes)
        await harness.tearDown()
    }
}

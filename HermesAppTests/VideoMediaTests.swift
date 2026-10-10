import AVFoundation
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HermesMobile

/// A video in the chat is a playable poster, and opening it offers what the image viewer offers.
///
/// Before this, `MediaAttachmentRow` drew a `.video` ref as a film-glyph chip unless it was an `http(s)` link, and the chip opened Quick Look; nothing in the app put a video on the pasteboard or into Photos.
final class VideoMediaTests: XCTestCase {

    // MARK: Nothing moves until the person asks, and what the host says is read right

    /// The host's HEAD on an oversize file answers 413 before stating any length (`files.py:544-551`), so the status itself is the size answer, and it is not something a retry can change.
    func testA413FromTheHostIsTheSizeRefusalNotARetry() {
        let refusal = VideoMedia.Failure.forStatus(413, limit: VideoMedia.byteLimit)
        XCTAssertEqual(refusal, .tooLarge(bytes: 0, limit: VideoMedia.byteLimit))
        XCTAssertEqual(refusal.errorDescription, "That video is over the limit; the app loads videos up to 104.9 MB.")
        XCTAssertFalse(refusal.isRetryable)
        XCTAssertEqual(VideoMedia.Failure.forStatus(415, limit: VideoMedia.byteLimit), .notAVideo)
        XCTAssertFalse(VideoMedia.Failure.notAVideo.isRetryable)
        XCTAssertEqual(VideoMedia.Failure.forStatus(500, limit: VideoMedia.byteLimit), .status(500))
        XCTAssertTrue(VideoMedia.Failure.status(500).isRetryable)
        XCTAssertTrue(VideoMedia.Failure.notConnected.isRetryable)
    }

    /// A row appearing asks only for the size; the file is not written until a tap.
    func testProbingAVideoStatesItsSizeWithoutWritingTheCache() async throws {
        let bytes = Data(repeating: 0x42, count: 3_000)
        let path = "data:video/mp4;base64," + bytes.base64EncodedString()
        let probe = try await VideoMedia.probe(for: path, gateway: nil)
        XCTAssertEqual(probe.bytes, 3_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VideoMedia.cacheURL(for: path).path), "the probe downloaded the file")
        XCTAssertNil(VideoMedia.cachedFile(for: path))
    }

    /// Two rows (or one row twice) asking for the same clip share one transfer.
    func testTwoRequestsForOnePathShareOneDownload() async throws {
        let counter = Counter()
        let downloads = VideoDownloads { path in
            await counter.increment()
            try await Task.sleep(nanoseconds: 150_000_000)
            return URL(fileURLWithPath: "/tmp/\(path).mp4")
        }
        async let first = downloads.file(for: "clip")
        async let second = downloads.file(for: "clip")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        let started = await counter.value
        XCTAssertEqual(started, 1, "the same path was downloaded \(started) times at once")
    }

    /// The transfer stops when the last one waiting for it has gone away (the viewer closed, the row left the screen).
    func testCancellingTheLastWaiterCancelsTheTransfer() async throws {
        let counter = Counter()
        let downloads = VideoDownloads { path in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                await counter.increment()
                throw error
            }
            return URL(fileURLWithPath: "/tmp/\(path).mp4")
        }
        let waiter = Task { try await downloads.file(for: "clip") }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        _ = try? await waiter.value
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = await counter.value
        XCTAssertEqual(cancelled, 1, "the download kept running after nobody wanted it")
        let inFlight = await downloads.inFlightCount
        XCTAssertEqual(inFlight, 0)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    // MARK: What plays

    func testTheContainersIOSPlaysAreVideosTheChatPlays() {
        for path in [#"C:\Users\you\Downloads\clip.mp4"#, "/tmp/out/render.MOV", "~/Movies/take.m4v", "https://host.example/clip.mp4?v=2"] {
            XCTAssertTrue(VideoMedia.isPlayable(path), "\(path) is a container iOS plays")
            XCTAssertEqual(MediaDirective.kind(of: path), .video)
        }
    }

    func testTheRestOfDesktopsVideoSetKeepsTheFileChip() {
        for path in ["/tmp/out/render.mkv", "/tmp/out/render.avi", "/tmp/out/render.webm", "/tmp/out/notes.md", "/tmp/out/noext"] {
            XCTAssertFalse(VideoMedia.isPlayable(path), "\(path) is not something AVFoundation plays natively")
        }
        XCTAssertEqual(MediaDirective.kind(of: "/tmp/out/render.mkv"), .video, "still a video to the chip's glyph and label")
    }

    // MARK: The cap

    func testTheCapIsTheServersOwnAndIsReadBeforeTheBodyMoves() {
        XCTAssertEqual(VideoMedia.byteLimit, 100 * 1024 * 1024)
        XCTAssertTrue(VideoMedia.admits(expectedLength: Int64(VideoMedia.byteLimit)))
        XCTAssertFalse(VideoMedia.admits(expectedLength: Int64(VideoMedia.byteLimit) + 1))
        XCTAssertTrue(VideoMedia.admits(expectedLength: -1), "an unknown length is admitted and measured on disk afterwards")
        XCTAssertEqual(
            VideoMedia.Failure.tooLarge(bytes: 230 * 1000 * 1000, limit: VideoMedia.byteLimit).errorDescription,
            "That video is 230 MB; the app loads videos up to 104.9 MB."
        )
    }

    func testAnOversizedInlineVideoIsRefusedAndNothingIsWritten() async {
        let path = "data:video/mp4;base64," + Data(repeating: 0x42, count: 4_096).base64EncodedString()
        do {
            _ = try await VideoMedia.localFile(for: path, gateway: nil, limit: 1_024)
            XCTFail("4 KB under a 1 KB cap must be refused")
        } catch {
            XCTAssertEqual(error as? VideoMedia.Failure, .tooLarge(bytes: 4_096, limit: 1_024))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: VideoMedia.cacheURL(for: path).path))
    }

    func testAnInlineImageIsNotAVideo() async {
        let path = "data:image/png;base64,iVBORw0KGgo="
        do {
            _ = try await VideoMedia.localFile(for: path, gateway: nil)
            XCTFail("an image data URL is not a video")
        } catch {
            XCTAssertEqual(error as? VideoMedia.Failure, .notAVideo)
        }
    }

    func testAGatewayPathWithoutABackendSaysSo() async {
        do {
            _ = try await VideoMedia.localFile(for: #"C:\Users\you\Downloads\nobody-\#(UUID().uuidString).mp4"#, gateway: nil)
            XCTFail("no backend, no file")
        } catch {
            XCTAssertEqual(error as? VideoMedia.Failure, .notConnected)
        }
    }

    // MARK: Where the file lives

    func testTheCacheFileKeepsTheContainerExtensionAndDiffersPerPath() {
        let a = VideoMedia.cacheURL(for: #"C:\Users\you\Downloads\clip.mp4"#)
        let b = VideoMedia.cacheURL(for: #"C:\Users\you\Downloads\clip.MOV"#)
        XCTAssertEqual(a.pathExtension, "mp4")
        XCTAssertEqual(b.pathExtension, "mov")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, VideoMedia.cacheURL(for: #"C:\Users\you\Downloads\clip.mp4"#), "the same path lands on the same file")
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "hermes-video")
    }

    // MARK: The poster

    func testThePosterIsAFrameUnderTheTranscriptsPixelBudgetWithTheDuration() async throws {
        let path = #"C:\Users\you\Downloads\poster-\#(UUID().uuidString).mp4"#
        let file = VideoMedia.cacheURL(for: path)
        try await MediaShowcase.makeMovie(to: file, seconds: 2)
        defer { try? FileManager.default.removeItem(at: file) }

        let local = try await VideoMedia.localFile(for: path, gateway: nil)
        XCTAssertEqual(local, file, "a file already in the cache is used without a fetch")

        let poster = try await VideoMedia.poster(for: path, file: file)
        XCTAssertLessThanOrEqual(max(poster.image.size.width * poster.image.scale, poster.image.size.height * poster.image.scale), CGFloat(DownsampledImage.transcriptMaxPixelSize))
        XCTAssertGreaterThan(poster.image.size.width, 0)
        XCTAssertEqual(poster.duration ?? 0, 2, accuracy: 0.2)
        XCTAssertNotNil(VideoMedia.cachedPoster(for: path), "the poster is kept so a row scrolling back draws at once")
    }

    func testTheDurationReadsLikeAClock() {
        XCTAssertEqual(VideoMedia.durationLabel(7), "0:07")
        XCTAssertEqual(VideoMedia.durationLabel(62.4), "1:02")
        XCTAssertEqual(VideoMedia.durationLabel(3_723), "1:02:03")
        XCTAssertNil(VideoMedia.durationLabel(.nan))
        XCTAssertNil(VideoMedia.durationLabel(-1))
    }

    // MARK: What the viewer offers

    func testTheVideoViewerOffersWhatTheImageViewerOffers() {
        XCTAssertEqual(MediaViewerControls<EmptyView>.actions, [.copy, .save, .share])
        XCTAssertEqual(MediaViewerAction.allCases.map { $0.label("video") }, ["Copy video", "Save video to Photos", "Share video"])
        XCTAssertEqual(MediaViewerAction.allCases.map { $0.label("image") }, ["Copy image", "Save image to Photos", "Share image"])
        XCTAssertEqual(MediaViewerAction.save.glyph, PhotoSave.State.idle.glyph, "the Save disc shows the same glyph in both viewers")
    }

    @MainActor
    func testCopyPutsTheVideoFileItselfOnThePasteboard() async throws {
        let path = #"C:\Users\you\Downloads\copy-\#(UUID().uuidString).mp4"#
        let file = VideoMedia.cacheURL(for: path)
        try await MediaShowcase.makeMovie(to: file, seconds: 1)
        defer { try? FileManager.default.removeItem(at: file) }

        UIPasteboard.general.items = []
        VideoViewer.copyToPasteboard(file)
        let provider = try XCTUnwrap(UIPasteboard.general.itemProviders.first, "nothing landed on the pasteboard")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.mpeg4Movie.identifier),
                      "the pasteboard carries \(provider.registeredTypeIdentifiers), not the movie")
    }
}

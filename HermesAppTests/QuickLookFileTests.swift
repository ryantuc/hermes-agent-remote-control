import Foundation
import XCTest

@testable import HermesMobile

/// The Quick Look previewer's file lifecycle, driven without presenting a sheet.
///
/// - BUG-081: every preview wrote its file into a fresh `tmp/quicklook-<UUID>/` directory and the sheet's `onDisappear` removed only the file, so one empty directory was left behind per preview, guaranteed; and a fetch that landed after the sheet had gone wrote a full copy of the document that nothing would ever remove.
/// - BUG-146 (`QuickLookPreview.swift` `fetch()`, `.decodeDataURL` grouped with `.askGateway`): a `data:` path was sent to the gateway's download route as if it were a filesystem path, so the bytes already in the string were never used and the whole payload travelled to the host as a query parameter.
/// - BUG-146 (`QuickLookPreview.swift` `fetch()`'s `failure` guard): once a fetch failed, nothing could fetch again; the sheet offered only Close.
@MainActor
final class QuickLookFileTests: XCTestCase {

    /// Records what the gateway was asked for and answers with `answer`, or throws while `failuresLeft` is above zero.
    private final class FixtureGateway: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        private var failuresLeft: Int
        let answer: Data

        init(answer: Data = Data("%PDF-1.4 fixture".utf8), failuresLeft: Int = 0) {
            self.answer = answer
            self.failuresLeft = failuresLeft
        }

        var requests: [String] { lock.withLock { _requests } }

        var gateway: MediaFileFetch.Gateway {
            { [self] path in
                let shouldFail: Bool = lock.withLock {
                    _requests.append(path)
                    guard failuresLeft > 0 else { return false }
                    failuresLeft -= 1
                    return true
                }
                if shouldFail { throw URLError(.timedOut) }
                return answer
            }
        }
    }

    /// Holds a fetch open until the test lets it go, so the sheet can be dismissed while the bytes are still on their way.
    private actor Latch {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private(set) var arrived = false

        func wait() async {
            arrived = true
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private static func quickLookDirectories() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return Set(names.filter { $0.hasPrefix("quicklook-") })
    }

    // MARK: BUG-081 — the directory goes with the file

    func testDiscardingThePreviewRemovesItsTemporaryDirectory() async throws {
        let fixture = FixtureGateway()
        let file = QuickLookFile(path: "/Users/agent/out/report.pdf")

        await file.load(gateway: fixture.gateway)
        let localURL = try XCTUnwrap(file.localURL, "the gateway answered, so there must be a file to preview")
        let directory = localURL.deletingLastPathComponent()
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("quicklook-"))
        XCTAssertEqual(localURL.lastPathComponent, "report.pdf", "Quick Look picks its renderer from the real name")

        file.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path), "the previewed file must go")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the quicklook-<UUID> directory was left behind: one orphan per preview (BUG-081)")
    }

    func testAFetchThatLandsAfterTheSheetWentLeavesNothingOnDisk() async throws {
        let latch = Latch()
        let before = Self.quickLookDirectories()
        let file = QuickLookFile(path: "/Users/agent/out/late.pdf")
        let gateway: MediaFileFetch.Gateway = { _ in
            await latch.wait()
            return Data("%PDF-1.4 late".utf8)
        }

        let loading = Task { await file.load(gateway: gateway) }
        var spins = 0
        while !(await latch.arrived), spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        let arrived = await latch.arrived
        XCTAssertTrue(arrived, "the fetch never reached the gateway, so the race was not set up")
        // The sheet is dismissed while the bytes are still in flight.
        file.discard()
        await latch.release()
        await loading.value

        XCTAssertNil(file.localURL, "a preview nobody is looking at must not hold a file")
        XCTAssertEqual(Self.quickLookDirectories().subtracting(before), [],
                       "the late fetch wrote a full copy of the document after onDisappear had already run (BUG-081, secondary race)")
    }

    // MARK: BUG-146 — a data: URL is decoded here, never sent to the gateway

    func testADataURLIsDecodedLocallyAndNeverSentToTheGateway() async throws {
        let fixture = FixtureGateway()
        let file = QuickLookFile(path: "data:text/plain;base64,aGVsbG8sIFF1aWNrIExvb2s=")

        await file.load(gateway: fixture.gateway)

        XCTAssertEqual(fixture.requests, [], "the data: URL went to /api/files/download as a filesystem path (BUG-146)")
        let localURL = try XCTUnwrap(file.localURL, "a decodable data: URL needs no backend at all")
        XCTAssertEqual(try Data(contentsOf: localURL), Data("hello, Quick Look".utf8))
        XCTAssertEqual(localURL.pathExtension, "txt", "Quick Look picks its renderer from the extension, so a data: URL is named for its media type")
        file.discard()
    }

    func testADataURLPreviewsWithNoBackendConnected() async throws {
        let file = QuickLookFile(path: "data:application/pdf;base64,JVBERi0xLjQ=")

        await file.load(gateway: nil)

        XCTAssertNil(file.failure, "\"Not connected to a backend\" is false for bytes that are already in the string")
        let localURL = try XCTUnwrap(file.localURL)
        XCTAssertEqual(localURL.pathExtension, "pdf")
        file.discard()
    }

    func testTheMarkdownPreviewerDecodesADataURLLocallyToo() async throws {
        let fixture = FixtureGateway()

        let data = try await MediaFileFetch.data(for: "data:text/markdown;base64,IyBUaXRsZQ==", gateway: fixture.gateway)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "# Title")
        XCTAssertEqual(fixture.requests, [], "MediaPreviewSheet sent the data: URL to the gateway as a path (BUG-146)")
    }

    func testAGatewayPathStillGoesToTheGateway() async throws {
        let fixture = FixtureGateway()

        let data = try await MediaFileFetch.data(for: #"C:\Users\you\Downloads\notes.md"#, gateway: fixture.gateway)

        XCTAssertEqual(data, fixture.answer)
        XCTAssertEqual(fixture.requests, [#"C:\Users\you\Downloads\notes.md"#])
    }

    func testAGatewayPathWithNoBackendSaysSo() async {
        do {
            _ = try await MediaFileFetch.data(for: "/Users/agent/out/report.pdf", gateway: nil)
            XCTFail("a gateway path cannot be fetched with no backend")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Not connected to a backend.")
        }
    }

    // MARK: BUG-146 — a failed fetch can be tried again

    func testAFailedFetchCanBeRetried() async throws {
        let fixture = FixtureGateway(failuresLeft: 1)
        let file = QuickLookFile(path: "/Users/agent/out/report.pdf")

        await file.load(gateway: fixture.gateway)
        XCTAssertNotNil(file.failure, "the first fetch timed out")
        XCTAssertNil(file.localURL)

        await file.retry(gateway: fixture.gateway)

        XCTAssertNil(file.failure, "a retry clears the failure it is answering")
        XCTAssertNotNil(file.localURL, "after one failure the sheet could only be closed; the retry never fetched (BUG-146)")
        XCTAssertEqual(fixture.requests.count, 2)
        file.discard()
    }
}

import Foundation
import XCTest

@testable import HermesMobile

/// BUG-146 ★ (`RemoteMedia.swift` `data(from:limit:)`) — the 32 MB cap could not stop the memory it exists to protect: `URLSession.shared.data(for:)` returns only once the whole body is in memory, so the `expectedContentLength` check after it refused a file that had already been downloaded, and an undeclared body was counted only after it had all arrived.
///
/// A stub `URLProtocol` on `URLSession.shared` (which is what `RemoteMedia` uses) serves a body in small timed chunks and counts what it handed over before the client stopped it. "Delivered" is the measure: a fetch that refuses at the headers or at the cap stops the transfer, and one that buffers first takes every chunk.
final class RemoteMediaCapTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ChunkedBodyStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ChunkedBodyStub.self)
        super.tearDown()
    }

    private static func url(_ name: String) -> URL {
        // A fresh path per test, so no answer can come out of `URLCache` under `.returnCacheDataElseLoad`.
        URL(string: "https://\(ChunkedBodyStub.host)/\(UUID().uuidString)/\(name)")!
    }

    func testADeclaredOversizeBodyIsRefusedBeforeItIsDownloaded() async throws {
        let url = Self.url("disk.img")
        let body = 256 * 1024
        ChunkedBodyStub.script(url, .init(status: 200, declaresLength: true, bodyBytes: body, chunkBytes: 1_024))

        do {
            _ = try await RemoteMedia.data(from: url, limit: 1_024)
            XCTFail("a body declared at \(body) bytes must be refused under a 1 KB cap")
        } catch {
            XCTAssertEqual(error as? RemoteMedia.Failure, .tooLarge(limit: 1_024))
        }

        let delivered = ChunkedBodyStub.delivered(url)
        XCTAssertLessThan(delivered, body / 4,
                          "\(delivered) of \(body) bytes were transferred before the Content-Length refusal: the body was buffered first (BUG-146)")
    }

    func testAnUndeclaredBodyIsCutOffAtTheCap() async throws {
        let url = Self.url("stream.bin")
        let body = 256 * 1024
        let limit = 8 * 1024
        ChunkedBodyStub.script(url, .init(status: 200, declaresLength: false, bodyBytes: body, chunkBytes: 1_024))

        do {
            _ = try await RemoteMedia.data(from: url, limit: limit)
            XCTFail("a \(body)-byte body must be refused under an \(limit)-byte cap")
        } catch {
            XCTAssertEqual(error as? RemoteMedia.Failure, .tooLarge(limit: limit))
        }

        let delivered = ChunkedBodyStub.delivered(url)
        XCTAssertLessThan(delivered, body / 4,
                          "\(delivered) of \(body) bytes were transferred: the cap was checked only after the whole body was in memory (BUG-146)")
    }

    func testAnErrorStatusIsRefusedWithoutReadingTheBody() async throws {
        let url = Self.url("missing.png")
        let body = 256 * 1024
        ChunkedBodyStub.script(url, .init(status: 404, declaresLength: true, bodyBytes: body, chunkBytes: 1_024))

        do {
            _ = try await RemoteMedia.data(from: url, limit: 1_024 * 1_024)
            XCTFail("a 404 is not a file")
        } catch {
            XCTAssertEqual(error as? RemoteMedia.Failure, .status(404))
        }

        XCTAssertLessThan(ChunkedBodyStub.delivered(url), body / 4, "an error page's body is not worth downloading")
    }

    func testABodyUnderTheCapArrivesWhole() async throws {
        let url = Self.url("chart.png")
        ChunkedBodyStub.script(url, .init(status: 200, declaresLength: false, bodyBytes: 3_000, chunkBytes: 1_024))

        let data = try await RemoteMedia.data(from: url, limit: 4_096)

        XCTAssertEqual(data.count, 3_000)
        XCTAssertEqual(data, ChunkedBodyStub.payload(count: 3_000))
    }

    func testABodyExactlyAtTheCapIsAccepted() async throws {
        let url = Self.url("exact.bin")
        ChunkedBodyStub.script(url, .init(status: 200, declaresLength: true, bodyBytes: 4_096, chunkBytes: 1_024))

        let data = try await RemoteMedia.data(from: url, limit: 4_096)

        XCTAssertEqual(data.count, 4_096)
    }

    func testAnEmptyBodyIsNotAFile() async throws {
        let url = Self.url("empty")
        ChunkedBodyStub.script(url, .init(status: 200, declaresLength: true, bodyBytes: 0, chunkBytes: 1_024))

        do {
            _ = try await RemoteMedia.data(from: url, limit: 4_096)
            XCTFail("an empty 200 is not a file")
        } catch {
            XCTAssertEqual(error as? RemoteMedia.Failure, .notAFile)
        }
    }
}

/// Serves a scripted body a chunk at a time on the loading thread's run loop, and stops the moment the client cancels.
private final class ChunkedBodyStub: URLProtocol {
    static let host = "remote-media-cap.invalid"

    struct Script {
        let status: Int
        let declaresLength: Bool
        let bodyBytes: Int
        let chunkBytes: Int
    }

    private static let lock = NSLock()
    private static var scripts: [URL: Script] = [:]
    private static var deliveredBytes: [URL: Int] = [:]

    static func script(_ url: URL, _ script: Script) {
        lock.withLock {
            scripts[url] = script
            deliveredBytes[url] = 0
        }
    }

    static func delivered(_ url: URL) -> Int {
        lock.withLock { deliveredBytes[url] ?? 0 }
    }

    /// Deterministic, not all one byte, so a test can tell a whole body from a truncated one.
    static func payload(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private var timer: Timer?
    private var sent = 0

    override func startLoading() {
        guard let url = request.url, let script = Self.lock.withLock({ Self.scripts[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if script.declaresLength { headers["Content-Length"] = String(script.bodyBytes) }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let body = Self.payload(count: script.bodyBytes)
        // On the thread that called startLoading, which is the one URLProtocol's client expects to be called back on.
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.sent < body.count else {
                timer.invalidate()
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            let end = min(self.sent + script.chunkBytes, body.count)
            self.client?.urlProtocol(self, didLoad: body.subdata(in: self.sent..<end))
            Self.lock.withLock { Self.deliveredBytes[url, default: 0] += end - self.sent }
            self.sent = end
        }
        self.timer = timer
        // The loading thread's current mode as well as the common ones, so the chunks flow whatever mode its run loop is in.
        let loop = RunLoop.current
        loop.add(timer, forMode: .common)
        if let mode = loop.currentMode, mode != .common { loop.add(timer, forMode: mode) }
    }

    override func stopLoading() {
        timer?.invalidate()
        timer = nil
    }
}

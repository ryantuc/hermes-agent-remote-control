import AVFoundation
import CryptoKit
import Foundation
import HermesServeKit
import UIKit

/// A video in the transcript: which files the phone can play, where their bytes come from, and the poster frame drawn in the chat.
/// Bytes always land in a file, never in memory: `AVPlayer` and `AVAssetImageGenerator` read from disk, Photos and the share sheet take a file URL, and a 100 MB clip costs nothing the transcript has to hold.
enum VideoMedia {

    /// The containers iOS plays natively; everything else in `MediaDirective`'s video set (avi, mkv, webm) keeps the file chip.
    static let playableExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The server's own managed-file ceiling (`_MANAGED_FILE_MAX_BYTES`, 100 MiB); past it the route answers 413, so refusing here first only saves the transfer. Higher than `RemoteMedia.byteLimit` because these bytes go to disk, not RAM.
    static let byteLimit = 100 * 1024 * 1024

    static func isPlayable(_ path: String) -> Bool {
        playableExtensions.contains(fileExtension(of: path))
    }

    static func fileExtension(of path: String) -> String {
        let name = MediaDirective.name(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Whether a transfer may start, from what the headers claim; an unknown length (-1) is admitted and checked again once the file is on disk.
    static func admits(expectedLength: Int64, limit: Int = byteLimit) -> Bool {
        expectedLength <= Int64(limit)
    }

    /// `m:ss`, or `h:mm:ss` from an hour up; nil for a duration the asset could not state.
    static func durationLabel(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    enum Failure: LocalizedError, Equatable {
        case tooLarge(bytes: Int64, limit: Int)
        case notAVideo
        case notConnected
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes, let limit):
                let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "over the limit"
                let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
                return "That video is \(size); the app loads videos up to \(cap)."
            case .notAVideo:
                return "That link didn't return a video."
            case .notConnected:
                return "Not connected to a backend."
            case .status(let code):
                return "The host answered \(code) for this video."
            }
        }

        /// The failure a non-success status means. The stream route refuses an oversize file with 413 before it states any length (`_managed_file_size`), and a non-media file with 415.
        static func forStatus(_ code: Int, limit: Int) -> Failure {
            switch code {
            case 413: return .tooLarge(bytes: 0, limit: limit)
            case 415: return .notAVideo
            default: return .status(code)
            }
        }

        /// Too large and not a video are answers, not transients: a retry would move the same request to the same refusal.
        var isRetryable: Bool {
            switch self {
            case .tooLarge, .notAVideo: return false
            case .notConnected, .status: return true
            }
        }
    }

    /// What a row can say about a clip before any of it moves: its size, when the host states one.
    struct Probe: Equatable, Sendable {
        let bytes: Int64?
    }

    // MARK: Where the file lives

    /// The cache file for a path, named by a digest so a Windows path or a URL becomes a filename, keeping the extension because AVFoundation and Quick Look read the container from it.
    static func cacheURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = fileExtension(of: path)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hermes-video", isDirectory: true)
        return directory.appendingPathComponent(ext.isEmpty ? digest : "\(digest).\(ext)")
    }

    /// The cached file for a path, if an earlier play, save or share already fetched it.
    static func cachedFile(for path: String) -> URL? {
        let file = cacheURL(for: path)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The authorised request for a gateway file, or nil without a backend. `GET /api/files/stream` rather than `download`: it answers HEAD, so the size is known before any of the body moves, and it refuses anything that is not media.
    typealias Gateway = @Sendable (String, String) async -> URLRequest?

    static func gateway(_ rest: RestAPI?) -> Gateway? {
        guard let rest else { return nil }
        return { path, method in await rest.managedFileStreamRequest(path: path, method: method) }
    }

    /// The file for `path`, fetched if the cache does not hold it. Size is checked twice: at the headers before the body moves, and on disk afterwards for a host that stated no length.
    static func localFile(for path: String, gateway: Gateway?, limit: Int = byteLimit) async throws -> URL {
        let destination = cacheURL(for: path)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch MediaDirective.fetchPlan(for: path) {
        case .decodeDataURL:
            guard let parsed = DataURL(path), parsed.mediaType.hasPrefix("video/") else { throw Failure.notAVideo }
            guard parsed.data.count <= limit else { throw Failure.tooLarge(bytes: Int64(parsed.data.count), limit: limit) }
            try parsed.data.write(to: destination, options: .atomic)
            return destination
        case .fetchRemote(let url):
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            try await download(URLRequest(url: url), head: head, to: destination, limit: limit)
            return destination
        case .askGateway:
            guard let gateway, let request = await gateway(path, "GET"), let head = await gateway(path, "HEAD") else {
                throw Failure.notConnected
            }
            try await download(request, head: head, to: destination, limit: limit)
            return destination
        }
    }

    /// The size of the clip at `path` without fetching it: the cache file, a `data:` URL's decoded length, or a HEAD. A host that does not answer HEAD (405) or states no length leaves the size unknown; a refusal the HEAD carries (413, 415, 404) is thrown.
    static func probe(for path: String, gateway: Gateway?, limit: Int = byteLimit) async throws -> Probe {
        if let file = cachedFile(for: path) {
            return Probe(bytes: try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
        }
        switch MediaDirective.fetchPlan(for: path) {
        case .decodeDataURL:
            guard let parsed = DataURL(path), parsed.mediaType.hasPrefix("video/") else { throw Failure.notAVideo }
            guard parsed.data.count <= limit else { throw Failure.tooLarge(bytes: Int64(parsed.data.count), limit: limit) }
            return Probe(bytes: Int64(parsed.data.count))
        case .fetchRemote(let url):
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            return try await headProbe(head, limit: limit)
        case .askGateway:
            guard let gateway, let head = await gateway(path, "HEAD") else { throw Failure.notConnected }
            return try await headProbe(head, limit: limit)
        }
    }

    private static func headProbe(_ head: URLRequest, limit: Int) async throws -> Probe {
        var request = head
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return Probe(bytes: nil) }
        // Only a size or type refusal is an answer; presigned storage links refuse HEAD (403) and still serve GET, so anything else leaves the size unknown and the download decides.
        if http.statusCode == 413 || http.statusCode == 415 { throw Failure.forStatus(http.statusCode, limit: limit) }
        guard (200..<300).contains(http.statusCode) else { return Probe(bytes: nil) }
        guard admits(expectedLength: http.expectedContentLength, limit: limit) else {
            throw Failure.tooLarge(bytes: http.expectedContentLength, limit: limit)
        }
        return Probe(bytes: http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
    }

    /// HEAD first for the length, then a download task, which streams to a temporary file the system owns until it is moved into the cache.
    private static func download(_ request: URLRequest, head: URLRequest, to destination: URL, limit: Int) async throws {
        var probe = head
        probe.timeoutInterval = 30
        if let probed = try? await URLSession.shared.data(for: probe),
           let http = probed.1 as? HTTPURLResponse {
            if http.statusCode == 413 || http.statusCode == 415 { throw Failure.forStatus(http.statusCode, limit: limit) }
            if (200..<300).contains(http.statusCode) && !admits(expectedLength: http.expectedContentLength, limit: limit) {
                throw Failure.tooLarge(bytes: http.expectedContentLength, limit: limit)
            }
        }
        try Task.checkCancellation()
        var get = request
        get.timeoutInterval = 300
        let (temporary, response) = try await URLSession.shared.download(for: get)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.forStatus(http.statusCode, limit: limit)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw Failure.notAVideo }
        guard size <= Int64(limit) else { throw Failure.tooLarge(bytes: size, limit: limit) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    // MARK: The poster

    struct Poster: @unchecked Sendable {
        let image: UIImage
        let duration: TimeInterval?
    }

    /// Posters already generated, so a row scrolling back into view draws at once.
    private static let posters = NSCache<NSString, PosterBox>()

    private final class PosterBox {
        let poster: Poster
        init(_ poster: Poster) { self.poster = poster }
    }

    static func cachedPoster(for path: String) -> Poster? {
        posters.object(forKey: path as NSString)?.poster
    }

    /// The first frame, downsampled to the transcript's pixel budget, with the duration. Decoded by AVFoundation on its own queue, never on the main actor.
    static func poster(for path: String, file: URL, maxPixelSize: Int = DownsampledImage.transcriptMaxPixelSize) async throws -> Poster {
        if let cached = cachedPoster(for: path) { return cached }
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let (cgImage, _) = try await generator.image(at: .zero)
        let seconds = try? await asset.load(.duration).seconds
        let poster = Poster(image: UIImage(cgImage: cgImage), duration: seconds.flatMap { $0.isFinite ? $0 : nil })
        posters.setObject(PosterBox(poster), forKey: path as NSString)
        return poster
    }
}

/// The transfers in flight, one per path. A second request for a clip that is already moving waits on the same transfer, and a transfer is cancelled the moment the last request waiting on it is (the viewer closed before the clip arrived).
actor VideoDownloads {
    typealias Fetch = @Sendable (String) async throws -> URL

    static let shared = VideoDownloads { path in try await VideoMedia.localFile(for: path, gateway: nil) }

    private struct Transfer {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }

    private let fetch: Fetch
    private var transfers: [String: Transfer] = [:]

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    var inFlightCount: Int { transfers.count }

    /// The file for `path`, joining a transfer already in flight or starting one with `starting` (the instance's own fetch when nil).
    func file(for path: String, starting: Fetch? = nil) async throws -> URL {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                join(path, waiter: waiter, continuation: continuation, starting: starting ?? fetch)
            }
        } onCancel: {
            Task { await self.leave(path, waiter: waiter) }
        }
    }

    private func join(_ path: String, waiter: UUID, continuation: CheckedContinuation<URL, Error>, starting: @escaping Fetch) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if transfers[path] != nil {
            transfers[path]?.waiters[waiter] = continuation
            return
        }
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<URL, Error>
            do { result = .success(try await starting(path)) } catch { result = .failure(error) }
            await self?.finish(path, token: token, result: result)
        }
        transfers[path] = Transfer(token: token, task: task, waiters: [waiter: continuation])
    }

    private func leave(_ path: String, waiter: UUID) {
        guard let continuation = transfers[path]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if let transfer = transfers[path], transfer.waiters.isEmpty {
            transfer.task.cancel()
            transfers[path] = nil
        }
    }

    private func finish(_ path: String, token: UUID, result: Result<URL, Error>) {
        guard let transfer = transfers[path], transfer.token == token else { return }
        transfers[path] = nil
        for continuation in transfer.waiters.values {
            continuation.resume(with: result)
        }
    }
}

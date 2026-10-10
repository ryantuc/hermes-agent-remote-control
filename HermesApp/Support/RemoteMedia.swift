import Foundation

/// Bytes for a media URL the agent put in a message: a link is not a Hermes route, so it cannot go to the authenticated `/api/media`, which answers 403 outside its own media roots (BUG-133).
/// Deliberately unauthenticated — the host is chosen by a model, so the backend's bearer token must never be sent there; ``MediaDirective/fetchPlan(for:)`` is the only place a gateway path and a link are told apart.
enum RemoteMedia {

    /// What a fetch can refuse to do, phrased for a person: `QuickLookSheet` puts `errorDescription` straight on screen.
    enum Failure: LocalizedError, Equatable {
        case status(Int)
        case tooLarge(limit: Int)
        case notAFile

        var errorDescription: String? {
            switch self {
            case .status(let code):
                return "The host answered \(code) for this file."
            case .tooLarge(let limit):
                return "That file is larger than \(limit / (1024 * 1024)) MB, so it wasn't downloaded."
            case .notAFile:
                return "That link didn't return a file."
            }
        }
    }

    /// 32 MB, so a mistyped link to a disk image cannot take the app's memory with it; the desktop applies no cap here, so the phone is deliberately the stricter side of parity.
    static let byteLimit = 32 * 1024 * 1024

    /// Fetch `url` into memory, refusing anything that is not a successful response under `limit`.
    /// The size is checked twice because `Content-Length` is a claim, not a guarantee: once at the headers, before any of the body is read, and again as the body arrives, so neither a declared nor an undeclared oversize body is ever held whole.
    static func data(from url: URL, limit: Int = byteLimit) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .returnCacheDataElseLoad

        // `bytes(for:)` returns at the headers; `data(for:)` returned only once the whole body was buffered, so the cap refused a file it had already downloaded (BUG-146).
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        do {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure.status(http.statusCode)
            }
            if response.expectedContentLength > Int64(limit) {
                throw Failure.tooLarge(limit: limit)
            }
            var buffer: [UInt8] = []
            if response.expectedContentLength > 0 { buffer.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard buffer.count < limit else { throw Failure.tooLarge(limit: limit) }
                buffer.append(byte)
            }
            guard !buffer.isEmpty else { throw Failure.notAFile }
            return Data(buffer)
        } catch {
            // Every refusal stops the transfer; left running, the body would keep arriving into a buffer nobody reads.
            bytes.task.cancel()
            throw error
        }
    }
}

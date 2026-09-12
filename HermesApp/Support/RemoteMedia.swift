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
    /// The size is checked twice because `Content-Length` is a claim, not a guarantee.
    static func data(from url: URL, limit: Int = byteLimit) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .returnCacheDataElseLoad

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        if response.expectedContentLength > 0, response.expectedContentLength > Int64(limit) {
            throw Failure.tooLarge(limit: limit)
        }
        guard data.count <= limit else { throw Failure.tooLarge(limit: limit) }
        guard !data.isEmpty else { throw Failure.notAFile }
        return data
    }
}

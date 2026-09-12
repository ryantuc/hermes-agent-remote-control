import Foundation

public struct ImageAttachResult: Sendable, Equatable {
    public let attached: Bool
    /// Absolute path on the gateway where the bytes landed.
    public let path: String
    public let name: String
    /// How many images are queued for the next turn.
    public let count: Int
    /// Informational only: images normally contribute nothing to the prompt text (reference-clients.md §6.3).
    public let text: String
}

public struct FileAttachResult: Sendable, Equatable {
    public let attached: Bool
    public let name: String
    public let path: String
    /// `@file:<ref>` — the client must splice this into the prompt text itself, since `file.attach` queues nothing (jsonrpc-methods §5.2).
    public let refText: String
    public let uploaded: Bool
}

/// Attachments over the JSON-RPC surface: `prompt.submit` carries no attachment field, so bytes go out of band first and the submit's `text` carries only reference tokens (reference-clients.md §6).
public struct AttachmentAPI: Sendable {
    /// 25 MB, error 4018 over the wall.
    public static let imageByteLimit = 25 * 1024 * 1024
    /// Extensions the gateway will actually accept; the desktop's client filter is wider and produces 4016s for `.svg`/`.ico`/`.tiff`, so this client matches the server instead.
    public static let allowedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    private let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    /// `image.attach_bytes {session_id, content_base64, filename}` with raw base64 and no `data:` prefix; this is the only path that works from a phone, since `image.attach {path}` needs a path the gateway can see (reference-clients.md §6.1).
    @discardableResult
    public func attachImageBytes(
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> ImageAttachResult {
        guard data.count <= Self.imageByteLimit else {
            throw HermesError.attachmentTooLarge(bytes: data.count, limit: Self.imageByteLimit)
        }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "content_base64": .string(data.base64EncodedString()),
            "filename": .string(filename),
        ])
        let result = try await client.request("image.attach_bytes", params: params)
        return ImageAttachResult(
            attached: result["attached"]?.coercedBool ?? false,
            path: result["path"]?.coercedString ?? "",
            name: result["name"]?.coercedString ?? filename,
            count: result["count"]?.coercedInt ?? 0,
            text: result["text"]?.coercedString ?? ""
        )
    }

    /// `file.attach {session_id, name, data_url}` → `{ref_text: "@file:…"}`, where `data_url` is a full `data:<mime>;base64,…` string unlike `image.attach_bytes`, which wants raw base64.
    @discardableResult
    public func attachFile(
        sessionID: String,
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> FileAttachResult {
        let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "name": .string(filename),
            "data_url": .string(dataURL),
        ])
        let result = try await client.request("file.attach", params: params)
        return FileAttachResult(
            attached: result["attached"]?.coercedBool ?? false,
            name: result["name"]?.coercedString ?? filename,
            path: result["path"]?.coercedString ?? "",
            refText: result["ref_text"]?.coercedString ?? "",
            uploaded: result["uploaded"]?.coercedBool ?? false
        )
    }

    /// `image.detach {session_id, path}` → the new queued count.
    @discardableResult
    public func detachImage(sessionID: String, path: String) async throws -> Int {
        let result = try await client.request(
            "image.detach",
            params: .object(["session_id": .string(sessionID), "path": .string(path)])
        )
        return result["count"]?.coercedInt ?? 0
    }

    /// Route a picked file the way the desktop does: images by kind, and everything else, PDFs included, as a `@file:` reference.
    public static func isAttachableAsImage(filename: String, mimeType: String) -> Bool {
        if mimeType.hasPrefix("image/") {
            let ext = (filename as NSString).pathExtension.lowercased()
            // Trust the extension over the declared MIME: the gateway sniffs magic bytes and rejects anything outside its six formats.
            return ext.isEmpty || allowedImageExtensions.contains(ext)
        }
        return false
    }
}

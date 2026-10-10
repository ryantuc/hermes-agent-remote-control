import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// A picked attachment as it will travel: the bytes, the name the gateway sees, and the MIME type the composer routes on.
public struct AttachmentPayload: Sendable, Equatable {
    public let data: Data
    public let filename: String
    public let mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// Attachments over the JSON-RPC surface: `prompt.submit` carries no attachment field, so bytes go out of band first and the submit's `text` carries only reference tokens (reference-clients.md §6).
public struct AttachmentAPI: Sendable {
    /// 25 MB, error 4018 over the wall.
    public static let imageByteLimit = 25 * 1024 * 1024
    /// The six formats every gateway takes under their own names. The live list is `cli._IMAGE_EXTENSIONS` (`hermes_cli/cli_terminal_input.py:33-36`, which also has `.tiff`/`.tif`/`.svg`/`.ico`), with exactly these six as the fallback when that import fails (`tui_gateway/prompt_attachments.py:74-79`); neither has `.heic`. `preparedForUpload` converts everything else that ImageIO can read.
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
            // Trust the extension over the declared MIME: the gateway takes the format from the extension, sniffs magic bytes only when there is none (`prompt_attachments.py:64-71`), and answers 4016 outside its list.
            return ext.isEmpty || allowedImageExtensions.contains(ext)
        }
        return false
    }

    /// The form a picked file travels in. Every picker arm passes its bytes through here before they are queued.
    ///
    /// BUG-077: a declared image whose name the gateway refuses (HEIC from a default-settings iPhone, HEIF, TIFF, AVIF, RAW) used to route as a `@file:` reference the model only sees as a binary-file stub. The gateway reads the format off the filename and has no `.heic` in its list, so the bytes are converted here instead: JPEG at the camera path's quality, or PNG when the source carries alpha. ImageIO copies the source's metadata, orientation tag included, into the new file, with no resampling. Bytes that are already a gateway format under the wrong name are renamed, not re-encoded; anything ImageIO cannot decode is returned unchanged and keeps its old route. Runs a full decode, so call it off the main actor.
    public static func preparedForUpload(_ payload: AttachmentPayload) -> AttachmentPayload {
        guard payload.mimeType.lowercased().hasPrefix("image/") else { return payload }
        let ext = (payload.filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, allowedImageExtensions.contains(ext) { return payload }
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let sniffed = CGImageSourceGetType(source) as String?
        else { return payload }
        let stem = ext.isEmpty ? payload.filename : (payload.filename as NSString).deletingPathExtension
        if let format = gatewayFormats[sniffed] {
            return AttachmentPayload(data: payload.data, filename: "\(stem).\(format.ext)", mimeType: format.mime)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasAlpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let target = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
        let output = NSMutableData()
        guard let format = gatewayFormats[target],
              let destination = CGImageDestinationCreateWithData(output as CFMutableData, target as CFString, 1, nil)
        else { return payload }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return payload }
        return AttachmentPayload(data: output as Data, filename: "\(stem).\(format.ext)", mimeType: format.mime)
    }

    /// The gateway's image formats by the type ImageIO reads off the bytes.
    private static let gatewayFormats: [String: (ext: String, mime: String)] = [
        UTType.png.identifier: ("png", "image/png"),
        UTType.jpeg.identifier: ("jpg", "image/jpeg"),
        UTType.gif.identifier: ("gif", "image/gif"),
        UTType.webP.identifier: ("webp", "image/webp"),
        UTType.bmp.identifier: ("bmp", "image/bmp"),
    ]
}

import Foundation

/// One answer from `POST /api/audio/transcribe`.
public struct Transcription: Sendable, Equatable {
    public let transcript: String
    /// Which provider actually ran (`openai`, `local`, …); nil on a silent recording.
    public let provider: String?

    public init(transcript: String, provider: String?) {
        self.transcript = transcript
        self.provider = provider
    }

    /// A recording with no speech comes back as 200 with an empty transcript, not an error, so a caller re-listens rather than reporting failure.
    public var isSilence: Bool { transcript.isEmpty }

    public init(json: JSONValue) {
        transcript = (json["transcript"]?.coercedString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = json["provider"]?.coercedString ?? ""
        provider = name.isEmpty ? nil : name
    }
}

/// Speech-to-text over the gateway — the Hermes dictation engine and the `stt` leg of voice chat.
public struct AudioAPI: Sendable {
    /// 25 MB, a 413 over the wall; checked here so a long recording fails before the upload.
    public static let transcriptionByteLimit = 25 * 1024 * 1024

    private let rest: RestAPI

    public init(rest: RestAPI) {
        self.rest = rest
    }

    /// `POST /api/audio/transcribe`.
    public func transcribe(data: Data, mimeType: String = "audio/m4a") async throws -> Transcription {
        guard !data.isEmpty else {
            // A zero-byte file is a recorder that never started, which is silence to the user, not the 400 the backend would return.
            return Transcription(transcript: "", provider: nil)
        }
        guard data.count <= Self.transcriptionByteLimit else {
            throw HermesError.attachmentTooLarge(bytes: data.count, limit: Self.transcriptionByteLimit)
        }
        let body: JSONValue = .object([
            "data_url": .string(Self.dataURL(for: data, mimeType: mimeType)),
            "mime_type": .string(mimeType),
        ])
        let json = try await rest.sendJSON("POST", "/api/audio/transcribe", body: body)
        return Transcription(json: json)
    }

    /// `data:<mime>;base64,<payload>` — the exact prefix the handler splits on, and it rejects anything without `;base64`.
    public static func dataURL(for data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

// MARK: - Dictation engine

/// Which recogniser turns speech into draft text.
public enum DictationEngine: String, Sendable, CaseIterable, Equatable {
    /// `SFSpeechRecognizer` on device: free, offline, and the only engine that can produce partial results.
    case onDevice
    /// The gateway's `stt.provider`, via ``AudioAPI``: whole-recording, so it arrives only after you stop speaking.
    case hermes

    public var label: String {
        switch self {
        case .onDevice: return "On-device"
        case .hermes: return "Hermes"
        }
    }

    /// Partial results need a streaming recogniser, and `/api/audio/transcribe` takes a finished file, so the "insert as you speak" row is disabled on `.hermes` rather than ignored.
    public var supportsPartialResults: Bool { self == .onDevice }
}

// MARK: - Splicing a transcript into a draft

/// Where dictated text lands in an existing draft; dictation is additive and never replaces what is already typed.
public enum DictationSplice {
    /// Append `transcript` to `draft`, inserting a separating space only when neither side already supplies one and the addition does not open with punctuation that hugs the previous word.
    public static func appending(_ transcript: String, to draft: String) -> String {
        let addition = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return draft }
        guard !draft.isEmpty else { return addition }

        if draft.last?.isWhitespace == true { return draft + addition }
        if let first = addition.first, Self.huggingPunctuation.contains(first) {
            return draft + addition
        }
        return draft + " " + addition
    }

    /// Replace the span a live partial result owns, against `base` as the draft stood when dictation started, because each revised partial must overwrite the previous one rather than stack.
    public static func replacingPartial(_ partial: String, base: String) -> String {
        appending(partial, to: base)
    }

    private static let huggingPunctuation: Set<Character> = [".", ",", "?", "!", ";", ":", "%", ")"]
}

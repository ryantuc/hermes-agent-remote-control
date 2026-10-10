import AVFoundation
import Observation

/// Read-aloud for assistant messages on device TTS — instant, free, offline — with only one message speaking at a time.
@MainActor
@Observable
final class ReadAloud: NSObject {
    static let shared = ReadAloud()

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var speakingID: String?
    /// The utterance that owns `speakingID` and the `.readAloud` claim. The synthesiser reports a cancellation after `stop()` has already released it, often after the next utterance has started, so only the current utterance's ending may release anything (BUG-146).
    @ObservationIgnored private var current: AVSpeechUtterance?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Start reading `text`; tapping the same message again stops it.
    func toggle(id: String, text: String) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        guard !text.isEmpty else { return }
        speak(text, id: id)
    }

    /// Speak without the toggle semantics — voice chat drives this directly, where every reply is a fresh utterance and there is nothing to toggle off.
    func speak(_ text: String, id: String) {
        let spoken = Self.spokenText(from: text)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        start(utterance, id: id)
        synthesizer.speak(utterance)
    }

    /// The bookkeeping half of `speak`, apart from the synthesiser so a test can drive it without audio.
    func start(_ utterance: AVSpeechUtterance, id: String) {
        // The session is claimed through the coordinator, not configured here: inside voice chat the category is already `.playAndRecord`, and `setCategory(.playback)` would cut the mic mid-conversation.
        try? AudioSession.shared.begin(.readAloud)
        current = utterance
        speakingID = id
    }

    /// Flatten the markdown the transcript displays into the spoken subset, reusing the transcript parser so links, formatting, headings and list markers follow the same rules as the on-screen reply.
    static func spokenText(from text: String) -> String {
        MarkdownParser.blocks(from: text).compactMap { block in
            switch block {
            case .prose(_, let lines):
                let prose = lines.compactMap { spokenInline($0.text) }
                    .joined(separator: "\n")
                return prose.isEmpty ? nil : prose
            case .code:
                return "Code block omitted."
            case .table(_, let headers, _, let rows):
                let tableRows = ([headers] + rows).compactMap { row -> String? in
                    let cells = row.compactMap { spokenInline($0) }
                    let spokenRow = cells.joined(separator: ", ")
                    return spokenRow.isEmpty ? nil : spokenRow
                }
                return tableRows.isEmpty ? nil : tableRows.joined(separator: ". ") + "."
            }
        }.joined(separator: "\n")
    }

    private static func spokenInline(_ source: String) -> String? {
        let plain = String(MarkdownParser.inline(source).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }

    func stop() {
        let wasSpeaking = current != nil
        current = nil
        speakingID = nil
        synthesizer.stopSpeaking(at: .immediate)
        if wasSpeaking { AudioSession.shared.end(.readAloud) }
    }

    /// The one place an utterance's ending releases its claim, and only while it is still the current one: the late `didCancel` for an utterance `stop()` already released would otherwise end the next utterance's claim and clear its id.
    fileprivate func ended(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        speakingID = nil
        AudioSession.shared.end(.readAloud)
    }

    /// True while an utterance is in flight — voice chat gates its listening window on this so it does not transcribe the reply.
    var isSpeaking: Bool { synthesizer.isSpeaking }
}

extension ReadAloud: AVSpeechSynthesizerDelegate {
    // Both endings release the use, never the session itself: deactivating here unconditionally tears the session out from under a live dictation or an open voice chat.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in ReadAloud.shared.ended(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in ReadAloud.shared.ended(utterance) }
    }
}

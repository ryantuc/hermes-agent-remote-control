import AVFoundation
import HermesServeKit
import Observation
import Speech

/// The turn-taking loop behind ``VoiceChatView`` (spec §4.5). This surface is
/// on-device only whatever the dictation setting says: `/api/audio/transcribe`
/// gives no streaming partials and no endpointing, so it cannot do barge-in.
///
/// BUG-071 A. The one failure voice chat cannot start without.
enum VoiceChatError: LocalizedError {
    case echoCancellationUnavailable

    var errorDescription: String? {
        switch self {
        case .echoCancellationUnavailable:
            return "This audio route cannot cancel echo, so voice chat would hear Hermes speaking and answer itself. Try the phone's own microphone or a wired headset."
        }
    }
}

@MainActor
@Observable
final class VoiceChatSession {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking

        var label: String {
            switch self {
            case .idle: return "Starting…"
            case .listening: return "Listening"
            case .thinking: return "Thinking"
            case .speaking: return "Speaking"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: return "Starting voice chat"
            case .listening: return "Listening. Speak now."
            case .thinking: return "Hermes is thinking."
            case .speaking: return "Hermes is speaking."
            }
        }

        /// Half-duplex is the deliberate BUG-140 boundary: recognition owns
        /// buffers only during the user's turn.
        var acceptsRecognition: Bool { self == .listening }
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Double = 0
    private(set) var failure: String?

    /// How long a pause ends your turn — long enough to survive drawing breath.
    private let endpointSilence: TimeInterval = 1.2

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var model: ChatModel?
    private weak var app: AppModel?
    private var loop: Task<Void, Never>?

    private var utterance = ""
    private var lastHeard = Date()
    private var speakingSince = Date()
    /// Cancellation does not make Speech callbacks synchronous. This makes a
    /// result from an old request harmless after the next listening edge.
    private var recognitionGeneration = 0
    /// Assistant entries already read out, seeded so opening the surface does
    /// not recite the whole conversation.
    private var spoken: Set<String> = []

    // MARK: Lifecycle

    func begin(model: ChatModel, app: AppModel) {
        guard phase == .idle, engine == nil else { return }
        self.model = model
        self.app = app
        spoken = Set(model.entries.filter { $0.kind == .assistant }.map(\.id))

        Task { @MainActor in
            if let refusal = await Dictation.requestAuthorization(engine: .onDevice) {
                failure = refusal
                return
            }
            guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                failure = "Voice chat needs on-device speech recognition, and this iPhone has no model for \(Locale.current.identifier). Dictation still works with the Hermes engine."
                return
            }
            AudioSession.shared.interruptionHandler = { [weak self] in self?.end() }
            do {
                try AudioSession.shared.begin(.voiceChat)
                try startEngine()
                rotateRequest()
                phase = .listening
                startLoop()
            } catch {
                // The handler is installed above the `do`, so this path owns
                // clearing it; `end()` clears it symmetrically.
                AudioSession.shared.interruptionHandler = nil
                AudioSession.shared.end(.voiceChat)
                failure = error.localizedDescription
            }
        }
    }

    func end() {
        loop?.cancel()
        loop = nil
        ReadAloud.shared.stop()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        AudioSession.shared.end(.voiceChat)
        AudioSession.shared.interruptionHandler = nil
        phase = .idle
        level = 0
        utterance = ""
    }

    // MARK: Audio

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // `.voiceChat` mode alone does not load echo cancellation, so without
        // this the tap hears the assistant's own TTS and answers itself; the
        // failure throws rather than being swallowed (BUG-071 A).
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw VoiceChatError.echoCancellationUnavailable
        }

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let power = Self.power(of: buffer)
            Task { @MainActor in
                guard let self else { return }
                // Half-duplex: the engine stays live for its audio route, but
                // recognition gets buffers only while listening.
                guard self.phase.acceptsRecognition else { return }
                self.request?.append(buffer)
                self.level = self.level * 0.7 + power * 0.3
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// A fresh recognition request per turn: `SFSpeechRecognitionTask` has a
    /// duration ceiling and a conversation outlives it.
    private func rotateRequest() {
        recognitionGeneration += 1
        let generation = recognitionGeneration
        task?.cancel()
        task = nil
        request?.endAudio()

        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.shouldReportPartialResults = true
        fresh.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) { fresh.addsPunctuation = true }
        request = fresh
        task = recognizer?.recognitionTask(with: fresh) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                self.heard(text)
            }
        }

    }

    /// Do not accept recognition results until `beginListening()` creates a
    /// fresh request; the input engine keeps running, so the route is unaffected.
    private func pauseRecognition() {
        recognitionGeneration += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

    private func beginListening() {
        rotateRequest()
        utterance = ""
        lastHeard = Date()
        phase = .listening
    }

    // MARK: Turn taking

    private func heard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard phase.acceptsRecognition else { return }
        utterance = trimmed
        lastHeard = Date()
    }

    private func startLoop() {
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// One 200 ms tick. Polling rather than observing: a silence deadline, an
    /// `isSpeaking` flag and a derived array are none of them change streams.
    private func tick() {
        guard let model else { return }

        switch phase {
        case .listening:
            guard !utterance.isEmpty,
                  Date().timeIntervalSince(lastHeard) >= endpointSilence
            else { return }
            submit(model: model)

        case .thinking:
            guard !model.isBusy,
                  let reply = model.entries.last(where: { $0.kind == .assistant }),
                  !reply.isStreaming,
                  !reply.text.isEmpty,
                  !spoken.contains(reply.id)
            else { return }
            spoken.insert(reply.id)
            guard VoicePreferences.speakReplies else {
                beginListening()
                return
            }
            pauseRecognition()
            phase = .speaking
            speakingSince = Date()
            ReadAloud.shared.speak(reply.text, id: reply.id)

        case .speaking:
            // The synthesiser does not report `isSpeaking` the instant it is
            // asked to start; without this grace the phase flips straight back.
            guard Date().timeIntervalSince(speakingSince) > 0.6 else { return }
            if !ReadAloud.shared.isSpeaking { beginListening() }

        case .idle:
            break
        }
    }

    private func submit(model: ChatModel) {
        let text = utterance
        utterance = ""
        guard !text.isEmpty else { return }
        pauseRecognition()
        guard model.sendVoiceTurn(text) else {
            failure = "Not connected — that turn was not sent."
            beginListening()
            return
        }
        failure = nil
        model.sendTapped()
        phase = .thinking
    }

    private static func power(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = Double(20 * log10(max(rms, 1e-7)))
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 55) / 55, 0), 1)
    }
}

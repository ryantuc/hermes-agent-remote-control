import AVFoundation
import HermesServeKit
import Observation
import Speech

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

/// The turn-taking loop behind ``VoiceChatView`` (spec §4.5). This surface is on-device only whatever the dictation setting says: `/api/audio/transcribe` gives no streaming partials and no endpointing, so it cannot do barge-in.
@MainActor
@Observable
final class VoiceChatSession {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        /// Ended by something other than Done, with the reason in `failure`. Terminal: Done and a fresh open start again.
        case stopped

        var label: String {
            switch self {
            case .idle: return "Starting…"
            case .listening: return "Listening"
            case .thinking: return "Thinking"
            case .speaking: return "Speaking"
            case .stopped: return "Stopped"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: return "Starting voice chat"
            case .listening: return "Listening. Speak now."
            case .thinking: return "Hermes is thinking."
            case .speaking: return "Hermes is speaking."
            case .stopped: return "Voice chat stopped."
            }
        }

        /// Half-duplex is the deliberate BUG-140 boundary: recognition owns
        /// buffers only during the user's turn.
        var acceptsRecognition: Bool { self == .listening }

        /// The conversation is under way: not still starting, and not already stopped.
        var isRunning: Bool { self == .listening || self == .thinking || self == .speaking }
    }

    /// What the loop does when a recognition request ends while it is still the user's turn (BUG-131 A).
    enum RecognitionEndResponse: Equatable {
        /// Not the user's turn: the request was already being retired.
        case ignore
        /// Words were heard before it ended: send them, as `Dictation` delivers what it has, rather than throw them away.
        case submit
        /// Nothing was heard: a fresh request, so Listening stays true.
        case restart
        /// It keeps ending as fast as it is restarted, so it is broken rather than idle: stop and say so.
        case stop
    }

    /// A request that ends this soon after it started counts as a quick failure.
    static let quickFailureWindow: TimeInterval = 1
    /// Quick failures in a row before the loop stops instead of restarting.
    static let quickFailureLimit = 5

    static func response(toRecognitionEndIn phase: Phase, heard: String, requestAge: TimeInterval, quickFailuresBefore: Int) -> RecognitionEndResponse {
        guard phase.acceptsRecognition else { return .ignore }
        guard heard.isEmpty else { return .submit }
        if requestAge < quickFailureWindow, quickFailuresBefore + 1 >= quickFailureLimit { return .stop }
        return .restart
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
    /// When the current recognition request started, and how many requests in a row ended within `quickFailureWindow` of starting with nothing heard.
    private var requestStartedAt = Date()
    private var quickFailures = 0
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
            AudioSession.shared.interruptionHandler = { [weak self] in
                self?.stop(reason: "Voice chat stopped because a call or another app took the audio. Tap Done and start it again.")
            }
            AudioSession.shared.routeChangeHandler = { [weak self] change in self?.audioRouteChanged(change) }
            do {
                try AudioSession.shared.begin(.voiceChat)
                try startEngine()
                rotateRequest()
                phase = .listening
                startLoop()
            } catch {
                // The handlers are installed above the `do`, so this path owns clearing them; `end()` clears them symmetrically. The `end` is owed whichever call threw, `begin` included: `AudioSession.begin` records the claim before it touches the session.
                AudioSession.shared.interruptionHandler = nil
                AudioSession.shared.routeChangeHandler = nil
                AudioSession.shared.end(.voiceChat)
                failure = error.localizedDescription
            }
        }
    }

    /// Done, leaving the screen, and backgrounding. A session that has already stopped keeps saying so.
    func end() {
        tearDown()
        if phase != .stopped { phase = .idle }
    }

    /// Ends the session for a reason the user did not choose, and leaves the screen saying Stopped and why rather than a phase that is no longer true.
    func stop(reason: String) {
        tearDown()
        phase = .stopped
        failure = reason
    }

    /// BUG-131 B. A device joining or leaving the route changes the audio path under the running engine, which left the waveform flat and the label on Listening; and the new route may not cancel echo, which `startEngine` refuses at the start (BUG-071 A). Stopping and saying why is the conservative answer to both; carrying on means rebuilding the engine on the new route, which only a phone can prove.
    func audioRouteChanged(_ change: AudioSession.RouteChange) {
        let what: String
        switch change {
        case .deviceLost: what = "a headset or speaker disconnected"
        case .deviceAdded: what = "a headset or speaker connected"
        case .noRoute: what = "no microphone is available"
        }
        stop(reason: "Voice chat stopped because \(what). Tap Done and start it again.")
    }

    private func tearDown() {
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
        AudioSession.shared.routeChangeHandler = nil
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
        requestStartedAt = Date()
        task = recognizer?.recognitionTask(with: fresh) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            // An error or a final result means this task will transcribe nothing more (BUG-131 A).
            let ended = error != nil || result?.isFinal == true
            let reason = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                if let text { self.heard(text) }
                if ended { self.recognitionEnded(reason: reason) }
            }
        }
    }

    /// BUG-131 A. Without this the loop polls a task that has stopped producing results, the endpoint never fires, and the screen keeps saying Listening.
    private func recognitionEnded(reason: String?) {
        guard let model else { return }
        let age = Date().timeIntervalSince(requestStartedAt)
        switch Self.response(toRecognitionEndIn: phase, heard: utterance, requestAge: age, quickFailuresBefore: quickFailures) {
        case .ignore:
            return
        case .submit:
            quickFailures = 0
            submit(model: model)
        case .restart:
            quickFailures = age < Self.quickFailureWindow ? quickFailures + 1 : 0
            rotateRequest()
        case .stop:
            let detail = reason.map { " (\($0))" } ?? ""
            stop(reason: "Speech recognition kept failing\(detail), so voice chat stopped. Tap Done and start it again.")
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
        quickFailures = 0
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

        case .idle, .stopped:
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

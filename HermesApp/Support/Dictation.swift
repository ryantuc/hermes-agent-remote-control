import AVFoundation
import HermesServeKit
import Observation
import Speech

/// Speech to draft text (spec §4.5). Two engines behind one control: on-device
/// `SFSpeechRecognizer` streams partial results and never leaves the phone;
/// Hermes posts an m4a to `/api/audio/transcribe` and arrives all at once.
@MainActor
@Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case listening
        /// Only reachable on `.hermes`: waiting on the provider round trip.
        case transcribing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The live hypothesis, on-device only. Empty on `.hermes`.
    private(set) var partial = ""
    /// Input level, 0…1, for the waveform. Smoothed — a raw reading jitters hard
    /// enough to look like a fault.
    private(set) var level: Double = 0

    var isListening: Bool { state == .listening }

    // On-device
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?

    // Hermes
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    private var audioAPI: AudioAPI?
    private var onFinal: ((String) -> Void)?
    private var onPartial: ((String) -> Void)?

    // MARK: Permissions

    /// Both grants, in the order the system wants them. Returns the first refusal
    /// as a message rather than a bool: they are different repair instructions.
    static func requestAuthorization(engine: DictationEngine) async -> String? {
        // Speech authorisation is only meaningful for the on-device recogniser.
        if engine == .onDevice {
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            switch speech {
            case .authorized: break
            case .denied, .restricted:
                return "Speech recognition is turned off for Hermes. Turn it on in Settings › Hermes, or switch the engine to Hermes in Settings › Voice."
            case .notDetermined: return "Speech recognition was not granted."
            @unknown default: return "Speech recognition is unavailable."
            }
        }
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard mic else {
            return "Hermes cannot use the microphone. Turn it on in Settings › Hermes."
        }
        return nil
    }

    // MARK: Start / stop

    func start(
        engine selected: DictationEngine,
        audioAPI: AudioAPI?,
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void
    ) {
        guard state != .listening else { return }
        self.audioAPI = audioAPI
        self.onPartial = onPartial
        self.onFinal = onFinal
        partial = ""

        Task { @MainActor in
            if let refusal = await Self.requestAuthorization(engine: selected) {
                state = .failed(refusal)
                return
            }
            AudioSession.shared.interruptionHandler = { [weak self] in
                self?.cancel()
            }
            do {
                try AudioSession.shared.begin(.dictation)
                switch selected {
                case .onDevice: try startOnDevice()
                case .hermes: try startRecording()
                }
                state = .listening
            } catch {
                endAudioSession()
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stop and deliver. On-device delivers what it already has; Hermes goes to
    /// the gateway first, which is why `.transcribing` is a visible state.
    func stop() {
        guard state == .listening else { return }
        switch (recorder, engine) {
        case (let recorder?, _):
            recorder.stop()
            self.recorder = nil
            state = .transcribing
            Task { await finishHermes() }
        default:
            let text = partial
            teardownOnDevice()
            endAudioSession()
            state = .idle
            if !text.isEmpty { onFinal?(text) }
            partial = ""
        }
    }

    /// Abandon without delivering — the interruption path, and Cancel.
    func cancel() {
        teardownOnDevice()
        recorder?.stop()
        recorder = nil
        removeRecording()
        endAudioSession()
        partial = ""
        level = 0
        if state != .idle { state = .idle }
    }

    /// BUG-071 C. Every teardown path goes through here, so the interruption
    /// handler `start` installs is always taken off again.
    ///
    /// Clearing unconditionally is correct rather than lucky: dictation and voice
    /// chat both own the microphone, so they cannot be live at the same time.
    private func endAudioSession() {
        AudioSession.shared.interruptionHandler = nil
        AudioSession.shared.end(.dictation)
    }

    // MARK: On-device

    private func startOnDevice() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable("On-device recognition is not available for \(Locale.current.identifier).")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The whole point of this engine: keep the audio on the phone, so there
        // is no silent fallback to Apple's servers when the device cannot.
        guard recognizer.supportsOnDeviceRecognition else {
            throw DictationError.unavailable("This iPhone has no on-device model for \(Locale.current.identifier). Switch the engine to Hermes in Settings › Voice.")
        }
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let power = Self.power(of: buffer)
            Task { @MainActor in self?.absorb(level: power) }
        }
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.onPartial?(self.partial)
                    if result.isFinal { self.deliverOnDeviceFinal() }
                } else if error != nil, self.state == .listening {
                    // A recogniser error after we have text is not worth throwing the text away for.
                    self.deliverOnDeviceFinal()
                }
            }
        }
    }

    private func deliverOnDeviceFinal() {
        let text = partial
        teardownOnDevice()
        endAudioSession()
        state = .idle
        partial = ""
        if !text.isEmpty { onFinal?(text) }
    }

    private func teardownOnDevice() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        level = 0
    }

    // MARK: Hermes

    private func startRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-dictation-\(UUID().uuidString).m4a")
        // AAC in an MP4 container — `audio/m4a` is on the gateway's accepted list,
        // so nothing is transcoded here.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw DictationError.unavailable("The microphone could not be started.")
        }
        self.recorder = recorder
        recordingURL = url
        startMetering()
    }

    private func finishHermes() async {
        defer {
            endAudioSession()
            removeRecording()
            level = 0
        }
        guard let url = recordingURL, let audioAPI else {
            state = .idle
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let result = try await audioAPI.transcribe(data: data)
            state = .idle
            // Silence is a 200 with an empty transcript; insert nothing and say nothing.
            if !result.isSilence { onFinal?(result.transcript) }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func removeRecording() {
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    private var meterTimer: Task<Void, Never>?

    private func startMetering() {
        meterTimer?.cancel()
        meterTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled, let recorder = self?.recorder, recorder.isRecording {
                recorder.updateMeters()
                let db = Double(recorder.averagePower(forChannel: 0))
                self?.absorb(level: Self.normalized(decibels: db))
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            self?.meterTimer = nil
        }
    }

    // MARK: Level

    private func absorb(level new: Double) {
        // Simple one-pole smoothing; the waveform should breathe, not strobe.
        level = level * 0.7 + new * 0.3
    }

    private static func power(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        return normalized(decibels: Double(20 * log10(max(rms, 1e-7))))
    }

    /// −55 dB … 0 dB mapped to 0…1. Below −55 is room tone.
    private static func normalized(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 55) / 55, 0), 1)
    }
}

enum DictationError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

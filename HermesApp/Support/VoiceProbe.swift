#if DEBUG
import AVFoundation
import HermesServeKit
import Speech

/// A DEBUG-only device probe (`-hermesVoiceProbe`) that renders each phrase to one wav, runs that file through both `SFSpeechRecognizer` on-device and `POST /api/audio/transcribe`, and prints the pair.
/// It also prints `supportsOnDeviceRecognition`, the value the simulator lies about, which is why this runs on hardware.
enum VoiceProbe {
    /// The vocabulary this app actually emits.
    static let phrases = [
        "Run xcodebuild in tilde slash Desktop slash hermes mobile",
        "Check out branch i o s slash band seven d",
        "Use model deepseek slash deepseek v4 flash 0731",
        "Open the file at tilde slash dot hermes slash config dot yaml",
    ]

    static func run(audioAPI: AudioAPI?) async {
        log("── on-device capability ──")
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        log("locale=\(Locale.current.identifier)")
        log("recognizer=\(recognizer == nil ? "nil" : "present") available=\(recognizer?.isAvailable ?? false)")
        log("supportsOnDeviceRecognition=\(recognizer?.supportsOnDeviceRecognition ?? false)")

        // Reaching this line proves the usage-description strings are in the bundle: a missing one is an immediate uncatchable crash, not an error return.
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        log("speechAuthorization=\(speechStatus.rawValue) (3 == authorized)")
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        log("microphoneGranted=\(micGranted)")

        guard let recognizer, speechStatus == .authorized else {
            log("stopping: no authorised recogniser")
            return
        }

        for (index, phrase) in phrases.enumerated() {
            log("── phrase \(index + 1) ──")
            log("spoken   : \(phrase)")
            guard let url = await synthesize(phrase) else {
                log("synthesis failed")
                continue
            }
            defer { try? FileManager.default.removeItem(at: url) }

            let bytes = (try? Data(contentsOf: url))?.count ?? 0
            let format = (try? AVAudioFile(forReading: url))?.processingFormat
            log("clip     : \(bytes) bytes, \(format.map { "\(Int($0.sampleRate))Hz ch=\($0.channelCount) \($0.commonFormat.rawValue)" } ?? "unreadable")")

            let localStart = Date()
            let local = await recognizeOnDevice(url: url, recognizer: recognizer)
            switch local {
            case .success(let text):
                log(String(format: "onDevice : %@  (%.2fs)", text, Date().timeIntervalSince(localStart)))
            case .failure(let error):
                let ns = error as NSError
                log(String(format: "onDevice : FAILED %@ (%@ %ld)  (%.2fs)",
                           ns.localizedDescription, ns.domain, ns.code,
                           Date().timeIntervalSince(localStart)))
            }

            guard let audioAPI else {
                log("hermes   : <no backend>")
                continue
            }
            let remoteStart = Date()
            do {
                let data = try Data(contentsOf: url)
                let result = try await audioAPI.transcribe(data: data, mimeType: "audio/wav")
                log(String(format: "hermes   : %@  (%.2fs, provider=%@)",
                           result.transcript, Date().timeIntervalSince(remoteStart), result.provider ?? "nil"))
            } catch {
                log("hermes   : failed — \(error.localizedDescription)")
            }
        }
        log("── probe complete ──")
        // A UI app never exits on its own, so `--console` would wait forever.
        exit(0)
    }

    // MARK: Render

    /// `AVSpeechSynthesizer.write` hands back PCM buffers that go straight into a linear-PCM wav, so the same bytes serve both engines with no transcode step in between.
    @MainActor
    private static func synthesize(_ text: String) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-probe-\(UUID().uuidString).wav")
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let rendered: URL? = await withCheckedContinuation { continuation in
            var file: AVAudioFile?
            var resumed = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // Zero-length buffer terminates the stream.
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: file == nil ? nil : url)
                    return
                }
                if file == nil {
                    // Int16, not the synthesiser's native Float32: an IEEE-float wav reads as silence to `SFSpeechRecognizer` (`kAFAssistantErrorDomain 1110`) though Whisper reads it happily.
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: pcm.format.sampleRate,
                        AVNumberOfChannelsKey: pcm.format.channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                    file = try? AVAudioFile(forWriting: url, settings: settings)
                }
                try? file?.write(from: pcm)
            }
        }
        // Only the zero-length buffer resumes the wait above, and nothing guaranteed the synthesiser lived to send it (BUG-146): the local's last use was `write`. This keeps it alive until the stream has ended.
        withExtendedLifetime(synthesizer) {}
        return rendered
    }

    // MARK: Recognise

    private static func recognizeOnDevice(
        url: URL,
        recognizer: SFSpeechRecognizer
    ) async -> Result<String, Error> {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(iOS 16.0, *) { request.addsPunctuation = true }

        return await withCheckedContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: .success(result.bestTranscription.formattedString))
                } else if let error {
                    resumed = true
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private static func log(_ message: String) {
        // `print`, not `NSLog`: NSLog goes to the unified log, and only stdout reaches `devicectl process launch --console`.
        print("[voice-probe] \(message)")
        fflush(stdout)
    }
}
#endif

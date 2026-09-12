import XCTest

@testable import HermesServeKit

/// The transcription payloads below are verbatim captures from a running
/// hermes-agent 0.20.0 backend — including the silence reply, which is the one
/// a hand-written fixture would have got wrong by assuming an error.
final class AudioAPITests: XCTestCase {

    private func json(_ raw: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    // MARK: - The wire shape

    /// Live capture: a ~9 s m4a clip of this app's own technical vocabulary.
    /// Note what the backend's own STT did to it — `xcodebuild` came back as
    /// "kotobuild" and `deepseek` as "deepseq". That is the evidence behind
    /// DECISIONS 22's engine default, and it is pinned here so a future change
    /// to the parsing cannot quietly be blamed for it.
    func testTranscriptionParsesLivePayload() {
        let live = json("""
        {"ok":true,
         "transcript":"runs kotobuild-in-tilde-desktop-hermes-mobile, then check out branch-ios-band-7d using model deepseq-deepseq-v4-0731.",
         "provider":"openai"}
        """)
        let result = Transcription(json: live)
        XCTAssertEqual(result.provider, "openai")
        XCTAssertTrue(result.transcript.hasPrefix("runs kotobuild"))
        XCTAssertFalse(result.isSilence)
    }

    /// **The one that matters for the hands-free loop.** A silent recording is
    /// a 200 with an empty transcript and a null provider — not a 400. Treating
    /// it as an error would put a failure row on screen at every pause.
    func testSilentRecordingIsSuccessNotFailure() {
        let live = json(#"{"ok":true,"transcript":"","provider":null}"#)
        let result = Transcription(json: live)
        XCTAssertTrue(result.isSilence)
        XCTAssertNil(result.provider)
        XCTAssertEqual(result.transcript, "")
    }

    /// The handler splits on the first comma and rejects any header without
    /// `;base64`, so the prefix is part of the contract, not cosmetics.
    func testDataURLCarriesTheBase64Marker() {
        let url = AudioAPI.dataURL(for: Data([0x00, 0x01, 0x02]), mimeType: "audio/m4a")
        XCTAssertTrue(url.hasPrefix("data:audio/m4a;base64,"))
        XCTAssertEqual(url.split(separator: ",").count, 2)
        XCTAssertEqual(String(url.split(separator: ",")[1]), Data([0x00, 0x01, 0x02]).base64EncodedString())
    }

    func testTranscriptIsTrimmed() {
        let result = Transcription(json: json(#"{"transcript":"  hello there \n","provider":"local"}"#))
        XCTAssertEqual(result.transcript, "hello there")
    }

    // MARK: - Engine capability

    /// The capability that shapes the settings screen: there is no streaming
    /// transcribe route, so only on-device recognition can insert as you speak.
    func testOnlyOnDeviceEngineSupportsPartialResults() {
        XCTAssertTrue(DictationEngine.onDevice.supportsPartialResults)
        XCTAssertFalse(DictationEngine.hermes.supportsPartialResults)
    }

    func testEngineRoundTripsThroughItsRawValue() {
        for engine in DictationEngine.allCases {
            XCTAssertEqual(DictationEngine(rawValue: engine.rawValue), engine)
        }
    }

    // MARK: - Splicing into a draft

    func testAppendsToAnEmptyDraftWithoutLeadingSpace() {
        XCTAssertEqual(DictationSplice.appending("run the tests", to: ""), "run the tests")
    }

    func testInsertsOneSeparatingSpace() {
        XCTAssertEqual(DictationSplice.appending("the tests", to: "run"), "run the tests")
    }

    func testDoesNotDoubleAnExistingTrailingSpace() {
        XCTAssertEqual(DictationSplice.appending("tests", to: "run the "), "run the tests")
    }

    /// Silence must not even move the caret.
    func testEmptyTranscriptLeavesTheDraftIdentical() {
        XCTAssertEqual(DictationSplice.appending("", to: "run the tests"), "run the tests")
        XCTAssertEqual(DictationSplice.appending("   \n ", to: "run the tests"), "run the tests")
        XCTAssertEqual(DictationSplice.appending("", to: ""), "")
    }

    /// Recognisers emit trailing punctuation as its own fragment; pushing it
    /// away from the word it belongs to reads as a typo.
    func testClosingPunctuationHugsThePrecedingWord() {
        XCTAssertEqual(DictationSplice.appending(".", to: "run the tests"), "run the tests.")
        XCTAssertEqual(DictationSplice.appending("?", to: "did it pass"), "did it pass?")
        XCTAssertEqual(DictationSplice.appending(", then ship it", to: "run the tests"),
                       "run the tests, then ship it")
    }

    /// **The partial-result bug this exists to prevent.** On-device recognition
    /// revises its hypothesis as you keep talking; each partial replaces the
    /// last against the *base* draft rather than stacking onto the previous
    /// partial.
    func testSuccessivePartialsReplaceRatherThanStack() {
        let base = "note:"
        let first = DictationSplice.replacingPartial("the quick", base: base)
        let second = DictationSplice.replacingPartial("the quick brown", base: base)
        let third = DictationSplice.replacingPartial("the quick brown fox", base: base)
        XCTAssertEqual(first, "note: the quick")
        XCTAssertEqual(second, "note: the quick brown")
        XCTAssertEqual(third, "note: the quick brown fox")
        XCTAssertFalse(third.contains("the quick the quick"))
    }

    func testPartialAgainstAnEmptyBaseIsJustThePartial()  {
        XCTAssertEqual(DictationSplice.replacingPartial("hello", base: ""), "hello")
    }

    // MARK: - The upload wall

    func testByteLimitMatchesTheBackendConstant() {
        XCTAssertEqual(AudioAPI.transcriptionByteLimit, 25 * 1024 * 1024)
    }
}

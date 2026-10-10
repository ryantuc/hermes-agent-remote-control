import AVFoundation
import XCTest

@testable import HermesMobile

/// BUG-146 (`ReadAloud.stop`): `stop()` releases the `.readAloud` claim itself, and the synthesiser then reports the cancellation, which used to release it again. A claim is a set member, so the second release lands on whatever claim exists by then: the next utterance's.
final class ReadAloudClaimTests: XCTestCase {
    @MainActor
    func testALateCancellationCannotEndTheNextUtterancesClaim() async {
        AudioSession.shared.endAll()
        defer {
            ReadAloud.shared.stop()
            AudioSession.shared.endAll()
        }
        let first = AVSpeechUtterance(string: "first")
        ReadAloud.shared.start(first, id: "first")
        ReadAloud.shared.stop()
        XCTAssertFalse(AudioSession.shared.active.contains(.readAloud), "stop releases the claim it held")

        let next = AVSpeechUtterance(string: "next")
        ReadAloud.shared.start(next, id: "next")
        // Tapping another message's read-aloud is exactly this order: stop, start, and only then the synthesiser's report that the first was cancelled.
        ReadAloud.shared.speechSynthesizer(AVSpeechSynthesizer(), didCancel: first)

        let clobbered = await waitUntil(timeout: 0.5) { ReadAloud.shared.speakingID != "next" }
        XCTAssertFalse(clobbered, "the late cancellation of a stopped utterance cleared the live one's id")
        XCTAssertTrue(AudioSession.shared.active.contains(.readAloud), "the late cancellation of a stopped utterance ended the live one's claim")
    }

    @MainActor
    func testTheCurrentUtterancesEndingReleasesItsClaim() async {
        AudioSession.shared.endAll()
        defer {
            ReadAloud.shared.stop()
            AudioSession.shared.endAll()
        }
        let only = AVSpeechUtterance(string: "only")
        ReadAloud.shared.start(only, id: "only")

        ReadAloud.shared.speechSynthesizer(AVSpeechSynthesizer(), didFinish: only)

        let released = await waitUntil(timeout: 2) { ReadAloud.shared.speakingID == nil }
        XCTAssertTrue(released, "a finished utterance must clear its id")
        XCTAssertFalse(AudioSession.shared.active.contains(.readAloud), "a finished utterance must release its claim")
    }
}

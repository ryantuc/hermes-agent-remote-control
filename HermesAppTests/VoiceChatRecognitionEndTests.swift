import XCTest

@testable import HermesMobile

/// BUG-131 A: a recognition request that ends during the user's turn (an error, the task's duration ceiling, the on-device model evicted) must not leave the screen saying Listening at a microphone nobody is transcribing.
final class VoiceChatRecognitionEndTests: XCTestCase {
    @MainActor
    func testWordsHeardBeforeTheRequestEndedAreSent() {
        let response = VoiceChatSession.response(toRecognitionEndIn: .listening, heard: "what time is it", requestAge: 4, quickFailuresBefore: 0)
        XCTAssertEqual(response, .submit, "an ending is no reason to throw away what was heard; Dictation delivers it too")
    }

    @MainActor
    func testARequestThatEndsWithNothingHeardIsReplaced() {
        XCTAssertEqual(
            VoiceChatSession.response(toRecognitionEndIn: .listening, heard: "", requestAge: 30, quickFailuresBefore: 0),
            .restart,
            "a request that ended after a while with nothing heard needs a fresh one, or Listening is a lie"
        )
        XCTAssertEqual(
            VoiceChatSession.response(toRecognitionEndIn: .listening, heard: "", requestAge: 0.1, quickFailuresBefore: 0),
            .restart,
            "one quick failure is retried"
        )
    }

    @MainActor
    func testARecogniserThatFailsAsFastAsItIsRestartedStops() {
        let limit = VoiceChatSession.quickFailureLimit
        let quick = VoiceChatSession.quickFailureWindow / 2
        XCTAssertEqual(
            VoiceChatSession.response(toRecognitionEndIn: .listening, heard: "", requestAge: quick, quickFailuresBefore: limit - 1),
            .stop,
            "a recogniser that fails as fast as it is restarted is broken, and spinning on it hides that"
        )
        XCTAssertEqual(
            VoiceChatSession.response(toRecognitionEndIn: .listening, heard: "", requestAge: quick, quickFailuresBefore: limit - 2),
            .restart
        )
        XCTAssertEqual(
            VoiceChatSession.response(toRecognitionEndIn: .listening, heard: "", requestAge: 30, quickFailuresBefore: limit - 1),
            .restart,
            "a request that lived a while before ending is not a quick failure"
        )
    }

    @MainActor
    func testAnEndingOutsideTheUsersTurnIsIgnored() {
        for phase in [VoiceChatSession.Phase.idle, .thinking, .speaking] {
            XCTAssertEqual(
                VoiceChatSession.response(toRecognitionEndIn: phase, heard: "stale words", requestAge: 0.1, quickFailuresBefore: 0),
                .ignore,
                "\(phase) does not own recognition (BUG-140), so a late ending must not submit or restart"
            )
        }
    }
}

import XCTest

@testable import HermesMobile

/// A voice chat the system ended (a call, Siri, leaving the app) used to sit on "Starting…" with nothing on screen until Done. The same shape as BUG-131: the system said something and the surface kept drawing a state that was no longer true.
final class VoiceChatStopReasonTests: XCTestCase {
    @MainActor
    func testASessionTheSystemEndedSaysStoppedAndWhy() {
        AudioSession.shared.endAll()
        defer { AudioSession.shared.endAll() }
        let session = VoiceChatSession()
        try? AudioSession.shared.begin(.voiceChat)

        session.stop(reason: "Voice chat stopped because a call took the audio.")

        XCTAssertEqual(session.phase.label, "Stopped", "an interrupted session must not read Starting…")
        XCTAssertEqual(session.failure, "Voice chat stopped because a call took the audio.")
        XCTAssertFalse(AudioSession.shared.active.contains(.voiceChat), "stopping releases the microphone claim exactly as Done does")
    }

    @MainActor
    func testDoneAfterAStopKeepsTheReason() {
        AudioSession.shared.endAll()
        defer { AudioSession.shared.endAll() }
        let session = VoiceChatSession()

        session.stop(reason: "Voice chat stopped because a headset or speaker disconnected.")
        // `end()` also runs on leaving the screen and on backgrounding; neither may wipe the reason the user is reading.
        session.end()

        XCTAssertEqual(session.phase.label, "Stopped")
        XCTAssertEqual(session.failure, "Voice chat stopped because a headset or speaker disconnected.")
    }

    @MainActor
    func testOnlyARunningConversationIsStoppedWithAReasonOnLeavingTheApp() {
        // VoiceChatView's background handler keys off this: a refusal on screen (still idle) must not be overwritten, and a stopped session keeps its reason.
        XCTAssertFalse(VoiceChatSession.Phase.idle.isRunning)
        XCTAssertTrue(VoiceChatSession.Phase.listening.isRunning)
        XCTAssertTrue(VoiceChatSession.Phase.thinking.isRunning)
        XCTAssertTrue(VoiceChatSession.Phase.speaking.isRunning)
        XCTAssertFalse(VoiceChatSession.Phase.stopped.isRunning)
    }

    @MainActor
    func testDoneOnALiveSessionStillEndsQuietly() {
        AudioSession.shared.endAll()
        defer { AudioSession.shared.endAll() }
        let session = VoiceChatSession()
        try? AudioSession.shared.begin(.voiceChat)

        session.end()

        XCTAssertEqual(session.phase, .idle, "Done is the user's choice and needs no explanation")
        XCTAssertNil(session.failure)
        XCTAssertFalse(AudioSession.shared.active.contains(.voiceChat))
    }
}

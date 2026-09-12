import XCTest

@testable import HermesMobile

/// BUG-071 B — the app-level background callback releases audio claims while
/// leaving server-side chat turns alone. The view-level scenePhase handler ends
/// the VoiceChatSession itself; this test pins the shared teardown that backs
/// that handler and protects against a future no-op AppModel callback.
final class VoiceBackgroundLifecycleTests: XCTestCase {
    @MainActor
    func testBackgroundReleasesEveryAudioClaim() {
        AudioSession.shared.endAll()
        defer { AudioSession.shared.endAll() }

        try? AudioSession.shared.begin(.voiceChat)
        try? AudioSession.shared.begin(.readAloud)
        XCTAssertEqual(AudioSession.shared.active, [.voiceChat, .readAloud])

        AppModel().handleBackground()

        XCTAssertTrue(AudioSession.shared.active.isEmpty)
    }
}

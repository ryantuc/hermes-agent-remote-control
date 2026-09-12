import XCTest

@testable import HermesMobile

/// BUG-140: only the user's listening phase may feed Speech.
final class VoiceChatHalfDuplexTests: XCTestCase {
    @MainActor
    func testOnlyListeningAcceptsRecognition() {
        XCTAssertFalse(VoiceChatSession.Phase.idle.acceptsRecognition)
        XCTAssertTrue(VoiceChatSession.Phase.listening.acceptsRecognition)
        XCTAssertFalse(VoiceChatSession.Phase.thinking.acceptsRecognition)
        XCTAssertFalse(VoiceChatSession.Phase.speaking.acceptsRecognition)
        XCTAssertEqual(VoiceChatSession.Phase.speaking.label, "Speaking")
    }
}

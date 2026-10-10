import AVFoundation
import XCTest

@testable import HermesMobile

/// BUG-131 B: AirPods leaving, a headset arriving, or a route with no microphone used to change the audio path under a running voice chat with nothing listening. The simulator cannot change a route, so these tests post the system's own notification with the reason the phone would send.
final class AudioSessionRouteChangeTests: XCTestCase {
    @MainActor
    func testADeviceLeavingTheRouteReachesTheHandler() async {
        AudioSession.shared.endAll()
        defer { reset() }
        // The coordinator starts observing on its first use.
        try? AudioSession.shared.begin(.readAloud)
        var received: [AudioSession.RouteChange] = []
        AudioSession.shared.routeChangeHandler = { received.append($0) }

        post(.oldDeviceUnavailable)

        let arrived = await waitUntil(timeout: 2) { received.contains(.deviceLost) }
        XCTAssertTrue(arrived, "pulling AirPods out must reach the coordinator's route-change handler; received \(received)")
    }

    @MainActor
    func testOnlyDeviceChangesAreReported() async {
        AudioSession.shared.endAll()
        defer { reset() }
        try? AudioSession.shared.begin(.readAloud)
        var received: [AudioSession.RouteChange] = []
        AudioSession.shared.routeChangeHandler = { received.append($0) }

        // Our own `setCategory` posts `.categoryChange`; reporting it would stop voice chat the moment it started.
        post(.categoryChange)
        post(.routeConfigurationChange)
        post(.wakeFromSleep)
        post(.override)
        // A sentinel posted last: once it has arrived, everything posted before it has been delivered.
        post(.newDeviceAvailable)

        let arrived = await waitUntil(timeout: 2) { received.contains(.deviceAdded) }
        XCTAssertTrue(arrived, "a headset joining the route must be reported; received \(received)")
        XCTAssertEqual(received, [.deviceAdded], "only a device joining or leaving the route is a change voice chat must react to")
    }

    @MainActor
    func testTheReasonsMapToTheChangesVoiceChatCannotRideOut() {
        XCTAssertEqual(AudioSession.RouteChange(reason: .oldDeviceUnavailable), .deviceLost)
        XCTAssertEqual(AudioSession.RouteChange(reason: .newDeviceAvailable), .deviceAdded)
        XCTAssertEqual(AudioSession.RouteChange(reason: .noSuitableRouteForCategory), .noRoute)
        for reason: AVAudioSession.RouteChangeReason in [.unknown, .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange] {
            XCTAssertNil(AudioSession.RouteChange(reason: reason), "reason \(reason.rawValue) leaves the devices where they were")
        }
    }

    @MainActor
    func testARouteChangeStopsVoiceChatAndSaysWhy() {
        AudioSession.shared.endAll()
        defer { reset() }
        let session = VoiceChatSession()
        try? AudioSession.shared.begin(.voiceChat)

        session.audioRouteChanged(.deviceLost)

        XCTAssertEqual(session.phase.label, "Stopped", "the screen must stop claiming a state the route change ended")
        XCTAssertNotNil(session.failure, "the screen must say why it stopped")
        XCTAssertFalse(session.phase.acceptsRecognition)
        XCTAssertFalse(AudioSession.shared.active.contains(.voiceChat), "the microphone claim must be released")
    }

    @MainActor
    private func reset() {
        AudioSession.shared.routeChangeHandler = nil
        AudioSession.shared.endAll()
    }

    @MainActor
    private func post(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }
}

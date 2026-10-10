import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-146 (`ConnectionBannerView.swift` `captureDeadline`): filed as "a `.reconnecting` whose `retryIn` changes without a state change counts to a stale deadline".
///
/// That cannot happen while `GatewayConnectionState`'s `Equatable` is the synthesized one (`HermesClient.swift:5-9`): `retryInSeconds` is part of the value, so a new delay IS a state change and `.onChange(of: state)` recaptures the deadline. This file pins the premise the banner rests on, so a hand-written `==` that compared cases only would fail here instead of silently freezing the countdown.
final class ConnectionBannerDeadlineTests: XCTestCase {

    func testANewRetryDelayIsAStateChange() {
        XCTAssertNotEqual(
            GatewayConnectionState.reconnecting(attempt: 2, retryInSeconds: 4),
            GatewayConnectionState.reconnecting(attempt: 2, retryInSeconds: 8)
        )
    }

    func testANewAttemptIsAStateChange() {
        XCTAssertNotEqual(
            GatewayConnectionState.reconnecting(attempt: 2, retryInSeconds: 4),
            GatewayConnectionState.reconnecting(attempt: 3, retryInSeconds: 4)
        )
    }
}

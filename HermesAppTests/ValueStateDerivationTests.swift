import XCTest

@testable import HermesMobile

/// BUG-146 at `ValueState.swift:20`: `return lazy ? .unknown : .unknown` was a dead ternary, so `lazy` read as if it decided something. The behaviour was always "empty is unknown"; the ternary is gone and these pin the whole derivation so a later change to it is deliberate. No red: the change preserves behaviour.
final class ValueStateDerivationTests: XCTestCase {
    func testAnEmptyValueIsUnknownFromEitherShapeOfSessionInfo() {
        for connected in [true, false] {
            for lazy in [true, false] {
                XCTAssertEqual(ValueState.of("", connected: connected, lazy: lazy), .unknown, "connected=\(connected) lazy=\(lazy)")
            }
        }
    }

    func testAValueIsLiveWhileConnectedAndStaleWhileNot() {
        for lazy in [true, false] {
            XCTAssertEqual(ValueState.of("gpt-5", connected: true, lazy: lazy), .live)
            XCTAssertEqual(ValueState.of("gpt-5", connected: false, lazy: lazy), .stale)
        }
    }
}

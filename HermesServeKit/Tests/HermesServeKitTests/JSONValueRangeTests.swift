import XCTest

@testable import HermesServeKit

/// BUG-112 — the two Int accessors on `JSONValue` used to trap rather than
/// degrade.
///
/// Swift's `Int(_: Double)` is a *trapping* conversion: a finite double outside
/// Int64's range is a fatal error, not a nil. `coercedInt` guarded only
/// `isFinite`, which excludes NaN and the infinities and nothing else, and
/// `intValue`'s whole-number test (`truncatingRemainder(dividingBy: 1) == 0`)
/// is satisfied by every one of these values. JSON has no integer range limit,
/// so a backend — anomalous, malicious, or simply newer — could take the app
/// down through any of the forty wire-fed call sites `coercedInt` has.
///
/// The contract these pin is the one the file's own doctrine states for every
/// other accessor: a key that is absent, null, or unreadable degrades to "the
/// backend did not say" rather than failing anything.
final class JSONValueRangeTests: XCTestCase {

    /// `9223372036854775808` is `Int.max + 1` — the smallest whole number JSON
    /// can spell that Swift cannot hold. `1e30` is the shape a runaway counter
    /// or a unit-confused timestamp actually arrives in.
    func testCoercedIntDegradesRatherThanTrappingAboveInt64() {
        XCTAssertNil(JSONValue.number(9223372036854775808.0).coercedInt)
        XCTAssertNil(JSONValue.number(1e30).coercedInt)
        XCTAssertNil(JSONValue.number(Double.greatestFiniteMagnitude).coercedInt)
    }

    func testCoercedIntDegradesRatherThanTrappingBelowInt64() {
        XCTAssertNil(JSONValue.number(-9223372036854777000.0).coercedInt)
        XCTAssertNil(JSONValue.number(-1e30).coercedInt)
        XCTAssertNil(JSONValue.number(-Double.greatestFiniteMagnitude).coercedInt)
    }

    /// The string arm reaches the same conversion through `coercedDouble`, so
    /// an oversize *quoted* number has to degrade too.
    func testCoercedIntDegradesForAnOversizeNumericString() {
        XCTAssertNil(JSONValue.string("9223372036854775808").coercedInt)
        XCTAssertNil(JSONValue.string("1e30").coercedInt)
    }

    /// The non-finite cases were already guarded; they stay guarded.
    func testCoercedIntStillRejectsNaNAndInfinity() {
        XCTAssertNil(JSONValue.number(Double.nan).coercedInt)
        XCTAssertNil(JSONValue.number(Double.infinity).coercedInt)
        XCTAssertNil(JSONValue.number(-Double.infinity).coercedInt)
    }

    /// The fix must not narrow what already worked. Truncation toward zero is
    /// the documented behaviour of `coercedInt` and it survives.
    func testCoercedIntStillReadsEveryValueItAlreadyRead() {
        XCTAssertEqual(JSONValue.number(0).coercedInt, 0)
        XCTAssertEqual(JSONValue.number(42).coercedInt, 42)
        XCTAssertEqual(JSONValue.number(-42).coercedInt, -42)
        XCTAssertEqual(JSONValue.number(3.7).coercedInt, 3)
        XCTAssertEqual(JSONValue.number(-3.7).coercedInt, -3)
        XCTAssertEqual(JSONValue.string("128000").coercedInt, 128_000)
        XCTAssertEqual(JSONValue.bool(true).coercedInt, 1)
        XCTAssertNil(JSONValue.null.coercedInt)
    }

    /// The exact boundaries. `Int.min` is exactly `-2^63` and must still read;
    /// its negation is one past `Int.max` and must degrade.
    func testCoercedIntHoldsAtTheInt64Boundaries() {
        XCTAssertEqual(JSONValue.number(Double(Int.min)).coercedInt, Int.min)
        XCTAssertNil(JSONValue.number(-Double(Int.min)).coercedInt)
        XCTAssertEqual(JSONValue.number(9007199254740992.0).coercedInt, 9_007_199_254_740_992)
    }

    /// `intValue` is the strict accessor — no string coercion, no truncation —
    /// and it had the same unguarded conversion.
    func testIntValueDegradesRatherThanTrappingOutsideInt64() {
        XCTAssertNil(JSONValue.number(9223372036854775808.0).intValue)
        XCTAssertNil(JSONValue.number(1e30).intValue)
        XCTAssertNil(JSONValue.number(-1e30).intValue)
        XCTAssertEqual(JSONValue.number(7).intValue, 7)
        XCTAssertNil(JSONValue.number(7.5).intValue)
    }

    /// The end-to-end shape: an event payload carrying the oversize number,
    /// decoded off the wire and read the way a reducer reads it. `start` and
    /// `count` on `terminal.read.request` are two of the payload-driven call
    /// sites, so this is the call that used to be fatal.
    func testAnEventPayloadCarryingAnOversizeNumberDecodesAndDegrades() throws {
        let line = """
            {"jsonrpc":"2.0","method":"event","params":{"type":"terminal.read.request",\
            "session_id":"a1b2c3d4","payload":{"start":1e30,\
            "count":9223372036854775808,"path":"/tmp/x"}}}
            """
        guard case .event(let event) = try JSONRPCCodec.decodeFrame(line) else {
            return XCTFail("expected an event frame")
        }

        XCTAssertEqual(event.type, "terminal.read.request")
        XCTAssertNil(event.payload["start"]?.coercedInt)
        XCTAssertNil(event.payload["count"]?.coercedInt)
        XCTAssertEqual(event.payload["path"]?.stringValue, "/tmp/x")
    }
}

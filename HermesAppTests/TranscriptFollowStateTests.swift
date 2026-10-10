import XCTest

@testable import HermesMobile

/// The follow decision while a reply streams: who is still following, and when the trailing scroll fires.
///
/// The view used the bottom sentinel's near-bottom flag alone, so one chunk taller than `TranscriptScroll.Geometry.slack` (a table, a code block, the footer arriving at the end of a turn) took the flag away, the next delta read "the reader scrolled back" and the follow stopped with the reader stranded a screen above the end. The judgement now distinguishes a reader the content carried off the tail from one who dragged.
final class TranscriptFollowStateTests: XCTestCase {
    private typealias Latch = TranscriptScroll.TailLatch
    private typealias Placement = TranscriptScroll.Placement<String>

    private let resting = TranscriptScrollReading(isTouching: false, movedOffset: false, isAtBottom: false)
    private let dragging = TranscriptScrollReading(isTouching: true, movedOffset: true, isAtBottom: false)
    private let coasting = TranscriptScrollReading(isTouching: true, movedOffset: true, isAtBottom: false)

    // MARK: Carried off the tail by the content

    /// The sentinel left the slack while no finger was on the transcript: the content grew. The reader is still following.
    func testAReaderTheContentCarriedPastTheSlackIsStillFollowing() {
        var latch = Latch()
        latch.record(isNearBottom: false, reading: resting)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: resting))
    }

    /// And the placed chat's decision is a follow, not a stand-still, even though the near-bottom flag is false.
    func testAPlacedChatFollowsAReaderTheContentCarriedOff() {
        var placement = Placement()
        _ = placement.decide(chat: "a", isNonEmpty: true, isNearBottom: false)
        _ = placement.decide(chat: "a", isNonEmpty: true, isNearBottom: false, afterLayout: true)
        XCTAssertEqual(placement.decide(chat: "a", isNonEmpty: true, isNearBottom: true, afterLayout: true), .followTail)

        XCTAssertEqual(
            placement.decide(chat: "a", isNonEmpty: true, isNearBottom: false, isFollowing: true),
            .followTail,
            "a reader the content pushed past the slack must still be followed"
        )
        XCTAssertEqual(
            placement.decide(chat: "a", isNonEmpty: true, isNearBottom: false, isFollowing: false),
            TranscriptScroll.Action.none,
            "and one who dragged away must not"
        )
        XCTAssertEqual(
            placement.decide(chat: "a", isNonEmpty: true, isNearBottom: false),
            TranscriptScroll.Action.none,
            "with no separate judgement the near-bottom flag decides, as before"
        )
    }

    // MARK: Left by hand

    /// The sentinel left the slack under a drag: on purpose, and nothing follows.
    func testAReaderWhoDraggedOffTheTailIsNotFollowing() {
        var latch = Latch()
        latch.record(isNearBottom: false, reading: dragging)
        let released = TranscriptScrollReading(isTouching: false, movedOffset: false, isAtBottom: false)
        XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: released))
    }

    /// The content carried the reader off first, then they dragged further before any repair: the sentinel's edge reported nothing new, so the drag is noticed at the next decision.
    func testADragAfterBeingCarriedOffIsADeparture() {
        var latch = Latch()
        latch.record(isNearBottom: false, reading: resting)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: resting))

        latch.noteDeparture(isNearBottom: false, reading: coasting)
        let released = TranscriptScrollReading(isTouching: false, movedOffset: false, isAtBottom: false)
        XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: released))
    }

    /// Moving the offset while still within the slack is not a departure, and neither is a reading that ends at the bottom.
    func testADragThatStaysNearTheTailIsNotADeparture() {
        var latch = Latch()
        latch.noteDeparture(isNearBottom: true, reading: dragging)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: true, reading: resting))

        let toTheBottom = TranscriptScrollReading(isTouching: false, movedOffset: true, isAtBottom: true)
        latch.noteDeparture(isNearBottom: false, reading: toTheBottom)
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: resting))
    }

    /// The scroll-to-latest disc and the reader's own send mean "follow again".
    func testRejoiningClearsADeparture() {
        var latch = Latch()
        latch.record(isNearBottom: false, reading: dragging)
        XCTAssertFalse(latch.wasAtTail(isNearBottom: false, reading: resting))
        latch.rejoin()
        XCTAssertTrue(latch.wasAtTail(isNearBottom: false, reading: resting))
    }

    // MARK: The trailing scroll

    /// A burst of growth is one scroll: every arm supersedes the one before it, and only the last token fires.
    func testABurstOfGrowthEarnsOneTrailingScroll() {
        var settle = TranscriptScroll.FollowSettle()
        let first = settle.arm()
        let second = settle.arm()
        let third = settle.arm()
        XCTAssertFalse(settle.fire(token: first))
        XCTAssertFalse(settle.fire(token: second))
        XCTAssertTrue(settle.fire(token: third))
        XCTAssertFalse(settle.fire(token: third), "a token fires once")
        XCTAssertNil(settle.pending)
    }
}

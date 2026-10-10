import XCTest

@testable import HermesServeKit

/// BUG-146 — `SessionActivity.enforceBounds` evicted with a `firstIndex(where:)` and a
/// `remove(at:)` per excess row inside a `while`, which is quadratic on a roster of finished rows.
/// Harmless at the 32-row cap; the eviction ORDER is what the rest of the activity code relies on,
/// so it is pinned here before and after the rewrite.
final class SubagentBoundsTests: XCTestCase {
    private let limit = SessionActivity.subagentLimit

    private func row(_ index: Int, _ state: SubagentRow.State) -> SubagentRow {
        SubagentRow(id: "agent-\(index)", goal: "Task \(index)", state: state)
    }

    private func bounded(_ rows: [SubagentRow]) -> [String] {
        var activity = SessionActivity()
        activity.subagents = rows
        activity.enforceBounds()
        return activity.subagents.map(\.id)
    }

    func testTheOldestFinishedRowsGoFirstAndSurvivorsKeepTheirOrder() {
        // Even indices running, odd ones finished; three over the cap.
        let rows = (0..<(limit + 3)).map { row($0, $0 % 2 == 0 ? .running : .completed) }
        let kept = bounded(rows)
        XCTAssertEqual(kept.count, limit)
        XCTAssertEqual(kept, rows.map(\.id).filter { !["agent-1", "agent-3", "agent-5"].contains($0) })
    }

    func testTooFewFinishedRowsFallBackToTheOldestOfTheRest() {
        // One finished row, three over the cap: it goes, then the two oldest running rows.
        let rows = (0..<(limit + 3)).map { row($0, $0 == 10 ? .failed : .running) }
        let kept = bounded(rows)
        XCTAssertEqual(kept.count, limit)
        XCTAssertEqual(kept, rows.map(\.id).filter { !["agent-0", "agent-1", "agent-10"].contains($0) })
    }

    func testAnAllRunningRosterDropsItsOldestRows() {
        let rows = (0..<(limit + 2)).map { row($0, .running) }
        XCTAssertEqual(bounded(rows), Array(rows.map(\.id).dropFirst(2)))
    }

    func testARosterAtTheCapIsUntouched() {
        let rows = (0..<limit).map { row($0, $0 % 3 == 0 ? .interrupted : .running) }
        XCTAssertEqual(bounded(rows), rows.map(\.id))
    }

    /// The shape of the barrier: one pass over the roster, not a search and a shift per excess row.
    /// 20,000 finished rows is about 2×10⁸ element moves for the old loop and one pass for a linear
    /// one; the budget is two orders of magnitude above the linear cost.
    func testTheBarrierIsLinearOnALargeFinishedRoster() {
        let count = 20_000
        let rows = (0..<count).map { row($0, .completed) }
        var activity = SessionActivity()
        activity.subagents = rows
        let started = Date()
        activity.enforceBounds()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(activity.subagents.count, limit)
        XCTAssertEqual(activity.subagents.first?.id, "agent-\(count - limit)", "the newest rows survive")
        XCTAssertLessThan(elapsed, 1.0, "enforceBounds took \(elapsed) s on \(count) finished rows")
    }
}

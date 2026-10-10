import XCTest

@testable import HermesServeKit

/// BUG-146 — the keepalive probe raced the ping against a deadline task and never cancelled that
/// task when the pong won, so every answered probe (one per 20 s interval) left a 10-second sleeper
/// behind. `boundedPing` is the probe with its clock injectable.
final class PingProbeTimeoutTests: XCTestCase {
    /// What became of the deadline: started, then either cancelled or allowed to run out.
    private actor Deadline {
        private(set) var started = false
        private(set) var cancelled = false
        private(set) var ranOut = false

        func start() { started = true }
        func end(cancelled wasCancelled: Bool) {
            if wasCancelled { cancelled = true } else { ranOut = true }
        }
    }

    /// Holds a pong handler so a test can answer after the deadline.
    private final class HeldAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: (@Sendable (Bool) -> Void)?

        func hold(_ answer: @escaping @Sendable (Bool) -> Void) {
            lock.lock(); self.answer = answer; lock.unlock()
        }

        func fire(_ value: Bool) {
            lock.lock(); let answer = self.answer; lock.unlock()
            answer?(value)
        }
    }

    private func clock(_ deadline: Deadline) -> @Sendable (TimeInterval) async -> Void {
        { seconds in
            await deadline.start()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await deadline.end(cancelled: Task.isCancelled)
        }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    func testAnAnsweredPingCancelsItsDeadline() async {
        let deadline = Deadline()
        let answered = await WebSocketTransport.boundedPing(timeout: 30, sleep: clock(deadline)) { answer in
            answer(true)
        }
        XCTAssertTrue(answered)
        let cancelled = await waitUntil { await deadline.cancelled }
        XCTAssertTrue(cancelled, "a 30 s deadline must be cancelled once the pong is in, not left sleeping")
        let ranOut = await deadline.ranOut
        XCTAssertFalse(ranOut)
    }

    func testAPingThatFailsAlsoCancelsItsDeadline() async {
        let deadline = Deadline()
        let answered = await WebSocketTransport.boundedPing(timeout: 30, sleep: clock(deadline)) { answer in
            answer(false)
        }
        XCTAssertFalse(answered)
        let cancelled = await waitUntil { await deadline.cancelled }
        XCTAssertTrue(cancelled)
    }

    func testAnUnansweredPingFailsAtItsDeadline() async {
        let deadline = Deadline()
        let answered = await WebSocketTransport.boundedPing(timeout: 0.05, sleep: clock(deadline)) { _ in }
        XCTAssertFalse(answered, "no pong inside the window is a failed probe")
        let ranOut = await waitUntil { await deadline.ranOut }
        XCTAssertTrue(ranOut)
    }

    /// A pong arriving after the deadline answered must not resume the probe a second time, which a
    /// `CheckedContinuation` would trap on.
    func testALatePongIsIgnored() async {
        let held = HeldAnswer()
        let answered = await WebSocketTransport.boundedPing(timeout: 0.05) { answer in
            held.hold(answer)
        }
        XCTAssertFalse(answered)
        held.fire(true)
        held.fire(false)
    }
}

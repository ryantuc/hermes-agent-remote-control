import XCTest

@testable import HermesServeKit

/// BUG-065 — the keepalive that was never there.
///
/// A repo-wide grep for `sendPing|keepAlive|heartbeat|pingInterval` across the
/// kit and the app returned three hits and not one of them was a heartbeat: the
/// comment explaining why the *ping-gated open* was removed, a comment about
/// `autoReconnectEnabled`, and a comment about backend worker heartbeats. There
/// was no post-`gateway.ready` probe, no read deadline, and no
/// `NWPathMonitor`. On a carrier NAT that drops an idle binding without an RST
/// the receive loop parks forever, the client renders `.open`, and the only way
/// back is the user backgrounding the app.
///
/// Two things are pinned here: the counting policy, and the ordering constraint
/// that the whole feature has to obey — the probe starts on `gateway.ready` and
/// never during the handshake.
final class KeepaliveTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    /// Counts probes and answers, so a test can say what the socket did.
    private final class Socket: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Bool]
        private var probes = 0
        private var deaths = 0

        init(answers: [Bool]) { self.answers = answers }

        /// Answers from the script, then repeats its last answer forever.
        func probe() -> Bool {
            lock.lock(); defer { lock.unlock() }
            probes += 1
            if answers.count > 1 { return answers.removeFirst() }
            return answers.first ?? true
        }

        func died() {
            lock.lock(); deaths += 1; lock.unlock()
        }

        var probeCount: Int { lock.lock(); defer { lock.unlock() }; return probes }
        var deathCount: Int { lock.lock(); defer { lock.unlock() }; return deaths }
    }

    private func monitor(
        _ socket: Socket,
        interval: TimeInterval = 0.02,
        failureLimit: Int = 2
    ) -> KeepaliveMonitor {
        KeepaliveMonitor(
            interval: interval,
            failureLimit: failureLimit,
            probe: { socket.probe() },
            onDead: { socket.died() }
        )
    }

    // MARK: - The counting policy

    /// The headline: N consecutive misses take the socket down, which is what
    /// routes into the existing `.closed` teardown and the reconnect path that
    /// already works.
    func testConsecutiveMissesDeclareTheSocketDead() async {
        let socket = Socket(answers: [false])
        let keepalive = monitor(socket)
        keepalive.start()

        let died = await waitUntil { socket.deathCount == 1 }
        XCTAssertTrue(died, "a socket that never answers a ping must be declared dead")
        XCTAssertGreaterThanOrEqual(socket.probeCount, 2, "the limit is two misses, not one")

        keepalive.stop()
    }

    /// One miss is not a verdict. A single dropped pong on a live but congested
    /// cellular link is ordinary, and tearing the connection down for it would
    /// trade a rare stall for a frequent one.
    func testASingleMissDoesNotKillTheSocket() async {
        let socket = Socket(answers: [false, true])
        let keepalive = monitor(socket)
        keepalive.start()

        let probed = await waitUntil { socket.probeCount >= 5 }
        XCTAssertTrue(probed, "the monitor stopped probing")
        XCTAssertEqual(socket.deathCount, 0, "one missed pong must not close a working socket")
        XCTAssertEqual(keepalive.consecutiveFailures, 0, "an answer resets the count")

        keepalive.stop()
    }

    /// Misses have to be *consecutive*. Alternating answers on a flaky link
    /// must never accumulate into a teardown.
    func testAlternatingMissesNeverAccumulate() async {
        let socket = Socket(answers: [false, true, false, true, false, true, false, true])
        let keepalive = monitor(socket)
        keepalive.start()

        let probed = await waitUntil { socket.probeCount >= 8 }
        XCTAssertTrue(probed)
        XCTAssertEqual(socket.deathCount, 0, "the counter must reset on every answer")

        keepalive.stop()
    }

    /// A healthy socket is probed and never disturbed. This is the ordinary
    /// case and it runs for the whole life of every connection.
    func testAHealthySocketIsProbedAndLeftAlone() async {
        let socket = Socket(answers: [true])
        let keepalive = monitor(socket)
        keepalive.start()

        let probed = await waitUntil { socket.probeCount >= 3 }
        XCTAssertTrue(probed, "the probe must keep running, not fire once")
        XCTAssertEqual(socket.deathCount, 0)

        keepalive.stop()
    }

    func testStoppingHaltsTheProbe() async {
        let socket = Socket(answers: [true])
        let keepalive = monitor(socket)
        keepalive.start()
        _ = await waitUntil { socket.probeCount >= 2 }

        keepalive.stop()
        XCTAssertFalse(keepalive.isRunning)
        let settled = socket.probeCount

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertLessThanOrEqual(
            socket.probeCount, settled + 1,
            "a stopped monitor must not keep pinging a socket that is gone"
        )
    }

    /// Two `start`s on one socket must not produce two probe loops — twice the
    /// traffic and half the failure threshold.
    func testStartingTwiceDoesNotDoubleTheProbeLoop() async {
        let socket = Socket(answers: [true])
        let keepalive = monitor(socket, interval: 0.05)
        keepalive.start()
        keepalive.start()

        try? await Task.sleep(nanoseconds: 260_000_000)
        keepalive.stop()

        XCTAssertLessThanOrEqual(
            socket.probeCount, 8,
            "a second start armed a second loop: \(socket.probeCount) probes in ~5 intervals"
        )
    }

    /// The shipped numbers, asserted so a later edit has to mean it. Two misses
    /// at twenty seconds with a ten-second window puts detection inside a
    /// minute, and the twenty-second cadence also refreshes the NAT mapping
    /// this is defending against.
    func testTheShippedCadenceIsWhatTheCommentsClaim() {
        XCTAssertEqual(KeepaliveMonitor.defaultInterval, 20)
        XCTAssertEqual(KeepaliveMonitor.defaultFailureLimit, 2)
        XCTAssertEqual(KeepaliveMonitor.defaultPongTimeout, 10)
    }

    /// A failure limit below one would kill every connection on its first
    /// scheduling hiccup.
    func testTheFailureLimitCannotBeZero() {
        let socket = Socket(answers: [true])
        XCTAssertEqual(monitor(socket, failureLimit: 0).failureLimit, 1)
    }
}

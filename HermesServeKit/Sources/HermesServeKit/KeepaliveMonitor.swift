import Foundation

/// The liveness probe that runs for as long as a socket is open (BUG-065).
///
/// Carrier NAT drops idle TCP bindings without an RST or a FIN, so `receive` stays parked forever
/// and the client keeps rendering `.open` over a dead socket. Separated from `WebSocketTransport`
/// so the policy is testable without one: the transport supplies the probe and the funeral, this
/// owns the schedule and the counting. Armed on `gateway.ready`, never by `connect`, because a ping
/// during the handshake self-deadlocks.
final class KeepaliveMonitor: @unchecked Sendable {
    /// Returns true when the socket answered. False is a miss, not a verdict.
    typealias Probe = @Sendable () async -> Bool
    /// Called once, when the misses have added up.
    typealias OnDead = @Sendable () async -> Void

    /// Short enough to hold a NAT binding open and to notice it closing.
    static let defaultInterval: TimeInterval = 20
    /// Two, not one: a single missed pong on a congested cellular link is ordinary.
    static let defaultFailureLimit = 2
    /// The bounded window a pong must arrive in; a probe that never returns is a keepalive that
    /// never fires.
    static let defaultPongTimeout: TimeInterval = 10

    let interval: TimeInterval
    let failureLimit: Int

    private let probe: Probe
    private let onDead: OnDead
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var failures = 0

    /// Consecutive missed probes. Reset by any answer, and by `stop()`.
    var consecutiveFailures: Int {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return loop != nil
    }

    init(
        interval: TimeInterval = KeepaliveMonitor.defaultInterval,
        failureLimit: Int = KeepaliveMonitor.defaultFailureLimit,
        probe: @escaping Probe,
        onDead: @escaping OnDead
    ) {
        self.interval = interval
        self.failureLimit = max(1, failureLimit)
        self.probe = probe
        self.onDead = onDead
    }

    /// Idempotent: a second `start` is a no-op, not a second probe loop on the same socket.
    func start() {
        lock.lock()
        guard loop == nil else {
            lock.unlock()
            return
        }
        failures = 0
        // Not `Task { await self?.run() }`: the optional chain makes the Success type `Void?`.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
        loop = task
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let task = loop
        loop = nil
        failures = 0
        lock.unlock()
        task?.cancel()
    }

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }

            if await probe() {
                lock.lock()
                failures = 0
                lock.unlock()
                continue
            }

            lock.lock()
            failures += 1
            let count = failures
            lock.unlock()

            guard count >= failureLimit else { continue }
            lock.lock()
            loop = nil
            lock.unlock()
            // After clearing the loop handle: `onDead` calls `stop()`, and a monitor still holding
            // a handle to the task calling it would cancel itself mid-flight.
            await onDead()
            return
        }
    }
}

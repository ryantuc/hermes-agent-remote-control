import Foundation
import os

/// The cold-open instrument (BUG-123 / BUG-125): a stage clock over the path from route push to a laid-out transcript, plus a probe that posts a block to the main queue every 10 ms so a stall is measured rather than inferred.
/// Every entry point is a no-op shim outside `DEBUG`, and inside `DEBUG` the clock stays inert until the process is launched with `-hermesColdOpenTrace`.
enum ColdOpenTrace {
    #if DEBUG
    /// Read once: `ProcessInfo.arguments` is a bridged array and reading it per stage would be its own cost.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-hermesColdOpenTrace")

    private static let state = TraceState()

    /// Open a run: everything after this is timed relative to it, and any run already open is discarded, so the last `begin` wins.
    static func begin(_ label: String) {
        guard isEnabled else { return }
        state.begin(label)
    }

    /// Record a stage boundary; `detail` rides along on the printed line.
    static func mark(_ stage: String, _ detail: String = "") {
        guard isEnabled else { return }
        state.mark(stage, detail: detail, once: false)
    }

    /// `mark`, but only the first time this stage name is seen in this run.
    static func markOnce(_ stage: String, _ detail: String = "") {
        guard isEnabled else { return }
        state.mark(stage, detail: detail, once: true)
    }

    /// Time a synchronous span and record it as its own line; the return value is the body's, untouched.
    static func measure<T>(_ stage: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let started = CFAbsoluteTimeGetCurrent()
        let value = body()
        state.span(stage, seconds: CFAbsoluteTimeGetCurrent() - started)
        return value
    }

    /// Time a span that happens thousands of times and record the total and the count instead of a line each.
    static func measureAccumulating<T>(_ bucket: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let started = CFAbsoluteTimeGetCurrent()
        let value = body()
        state.accumulate(bucket, seconds: CFAbsoluteTimeGetCurrent() - started)
        return value
    }

    /// Print the run: every stage with its offset from `begin` and its delta from the stage before it, every measured span, and the worst main-thread stall seen since `begin`.
    static func report(_ note: String = "") {
        guard isEnabled else { return }
        state.report(note)
    }

    /// Start the main-thread responsiveness probe. Idempotent.
    static func startStallProbe() {
        guard isEnabled else { return }
        state.startProbe()
    }
    #else
    static let isEnabled = false
    @inline(__always) static func begin(_ label: String) {}
    @inline(__always) static func mark(_ stage: String, _ detail: String = "") {}
    @inline(__always) static func markOnce(_ stage: String, _ detail: String = "") {}
    @inline(__always) static func measure<T>(_ stage: String, _ body: () -> T) -> T { body() }
    @inline(__always) static func measureAccumulating<T>(_ bucket: String, _ body: () -> T) -> T { body() }
    @inline(__always) static func report(_ note: String = "") {}
    @inline(__always) static func startStallProbe() {}
    #endif
}

#if DEBUG
/// The clock behind `ColdOpenTrace`, locked rather than held in global `var`s because the stall probe writes from a background queue and everything else writes from the main actor.
final class TraceState: @unchecked Sendable {
    /// Both channels: `print` reaches `simctl launch --console` for a foreground run, `Logger` reaches `log stream` for a detached run with no controlling terminal.
    private static let log = Logger(subsystem: "com.hermes.mobile", category: "coldopen")

    private static func emit(_ line: String) {
        print(line)
        log.log("\(line, privacy: .public)")
    }

    private struct Stage {
        let name: String
        let detail: String
        let at: CFAbsoluteTime
    }

    private let lock = NSLock()
    private var label = ""
    private var epoch: CFAbsoluteTime?
    private var stages: [Stage] = []
    private var spans: [(name: String, seconds: Double)] = []
    private var seen: Set<String> = []
    /// Every main-queue hop the probe measured, as (offset from epoch, delay), kept whole rather than reduced to a maximum because the question is when the thread was unavailable, not only for how long.
    private var stalls: [(at: Double, delay: Double)] = []
    /// Named cost buckets: a per-row or per-line span summed over the window, with the call count beside it.
    private var buckets: [String: (calls: Int, seconds: Double)] = [:]
    private var probing = false

    func begin(_ label: String) {
        lock.lock()
        self.label = label
        epoch = CFAbsoluteTimeGetCurrent()
        stages = []
        spans = []
        seen = []
        stalls = []
        buckets = [:]
        lock.unlock()
        Self.emit("[coldopen] === begin \(label) ===")
    }

    func mark(_ stage: String, detail: String, once: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        guard epoch != nil else { return }
        if once {
            guard !seen.contains(stage) else { return }
            seen.insert(stage)
        }
        stages.append(Stage(name: stage, detail: detail, at: now))
    }

    func span(_ name: String, seconds: Double) {
        lock.lock()
        spans.append((name, seconds))
        lock.unlock()
    }

    func accumulate(_ bucket: String, seconds: Double) {
        lock.lock()
        var entry = buckets[bucket] ?? (0, 0)
        entry.calls += 1
        entry.seconds += seconds
        buckets[bucket] = entry
        lock.unlock()
    }

    func startProbe() {
        lock.lock()
        guard !probing else { lock.unlock(); return }
        probing = true
        lock.unlock()
        let queue = DispatchQueue(label: "hermes.coldopen.stallprobe", qos: .userInitiated)
        queue.async { [weak self] in
            while true {
                guard let self, self.isProbing else { return }
                let posted = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { [weak self] in
                    self?.recordHop(posted: posted, ran: CFAbsoluteTimeGetCurrent())
                }
                usleep(10_000)
            }
        }
    }

    private var isProbing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return probing
    }

    private func recordHop(posted: CFAbsoluteTime, ran: CFAbsoluteTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let epoch else { return }
        stalls.append((posted - epoch, ran - posted))
    }

    func report(_ note: String) {
        lock.lock()
        let label = self.label
        let epoch = self.epoch
        let stages = self.stages
        let spans = self.spans
        let stalls = self.stalls
        let buckets = self.buckets
        lock.unlock()
        guard let epoch else { return }
        var lines = ["[coldopen] === report \(label) \(note) ==="]
        var previous = epoch
        for stage in stages {
            lines.append(String(
                format: "[coldopen] %8.1f ms  (+%7.1f)  %@ %@",
                (stage.at - epoch) * 1000,
                (stage.at - previous) * 1000,
                stage.name,
                stage.detail
            ))
            previous = stage.at
        }
        for span in spans {
            lines.append(String(format: "[coldopen]   span %7.1f ms  %@", span.seconds * 1000, span.name))
        }
        for bucket in buckets.sorted(by: { $0.value.seconds > $1.value.seconds }) {
            lines.append(String(
                format: "[coldopen]   bucket %8.1f ms over %6d calls  %@",
                bucket.value.seconds * 1000,
                bucket.value.calls,
                bucket.key
            ))
        }
        // `worst` is the longest a queued block waited, which is the longest a tap would have waited.
        // The total is a union of intervals, not a sum of delays: ten hops queued behind one 5 s block each report nearly 5 s, and adding those up produces a number larger than the run.
        let worst = stalls.map(\.delay).max() ?? 0
        var blocked: Double = 0
        var windowStart: Double?
        var windowEnd: Double = 0
        for stall in stalls.filter({ $0.delay > 0.016 }).sorted(by: { $0.at < $1.at }) {
            let start = stall.at
            let end = stall.at + stall.delay
            if let open = windowStart, start <= windowEnd {
                windowEnd = max(windowEnd, end)
                _ = open
            } else {
                if let open = windowStart { blocked += windowEnd - open }
                windowStart = start
                windowEnd = end
            }
        }
        if let open = windowStart { blocked += windowEnd - open }
        lines.append(String(
            format: "[coldopen] main-thread: %d hops, worst wait %.1f ms, unavailable for %.1f ms in total",
            stalls.count,
            worst * 1000,
            blocked * 1000
        ))
        for stall in stalls.filter({ $0.delay > 0.100 }).sorted(by: { $0.delay > $1.delay }).prefix(8) {
            lines.append(String(
                format: "[coldopen]   stall %7.1f ms starting at %7.1f ms",
                stall.delay * 1000,
                stall.at * 1000
            ))
        }
        lines.append("[coldopen] === end \(label) ===")
        for line in lines { Self.emit(line) }
    }
}
#endif

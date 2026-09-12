import Foundation

/// An in-app ring buffer mirroring every line `TranscriptScrollLog` emits at notice level, so Diagnostics can Copy, Share and Clear the evidence without a tethered Mac (FEAT-034).
/// The per-delta `.followTail` debug line is deliberately not mirrored: three hundred of them arrive in a couple of seconds of streaming and evict every chrome and status line the reader is looking for.
/// Nothing here can carry content — the lines are heights, flags and a five-character fingerprint — so there is no redaction step.
/// Locked rather than actor-isolated: the call sites are hot and synchronous, and an `await` on a logging call is a change to the thing being measured.
final class TranscriptScrollBuffer: @unchecked Sendable {

    /// One mirrored line.
    struct Entry: Identifiable, Equatable {
        /// Monotonic within a run, not the index — the index moves under an entry every time the ring drops its oldest, which makes a `ForEach` keyed on it draw the wrong row.
        let id: UInt64
        let date: Date
        let text: String
    }

    /// The default depth: three hundred lines holds thirty seconds of oscillation with room for the run-up, about 18 KB.
    static let defaultCapacity = 300

    static let shared = TranscriptScrollBuffer()

    let capacity: Int

    private let lock = NSLock()
    private var storage: [Entry] = []
    private var nextID: UInt64 = 0

    init(capacity: Int = TranscriptScrollBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    /// Append one line, dropping the oldest once the ring is full.
    func append(_ text: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(id: nextID, date: date, text: text))
        nextID &+= 1
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Oldest first, which is the order the events happened in and the order the export reads in.
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var isEmpty: Bool { count == 0 }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }

    /// The buffer as plain text, one line per entry stamped to the millisecond, with `header` prepended and a blank line after it.
    func exportText(header: String? = nil) -> String {
        var lines: [String] = []
        if let header, !header.isEmpty {
            lines.append(header)
            lines.append("")
        }
        for entry in entries {
            lines.append("\(Self.stamp.string(from: entry.date))  \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Wall clock to the millisecond, in the phone's own zone.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

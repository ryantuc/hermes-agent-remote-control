import Foundation
import OSLog

/// BUG-050 instrumentation: every chrome transition and every scroll call site, so an oscillating transcript can be read back from the log stream.
/// FEAT-034 mirrors the notice-level lines into `TranscriptScrollBuffer`; the mirrored strings are built plainly rather than through `Logger` interpolation so the `.debug` follow-scroll keeps its laziness.
enum TranscriptScrollLog {
    private static let log = Logger(
        subsystem: "com.hermes.mobile.diagnostics",
        category: "transcript"
    )

    /// Which placement issued a scroll, named for the call site rather than the reason.
    enum Site: String {
        /// BUG-007's one-shot landing, and its bounded verify ladder.
        case initialPlacement
        /// P14 follow, once per streaming delta.
        case followTail
        /// The chrome resized and the reader was on the tail.
        case chromeReassert
        /// "Scroll to latest".
        case recoveryButton
        /// BUG-016: the transcript's own container changed height and the reader was at the tail, so a `containerResize` with no `chrome` line beside it came from outside the stack.
        case containerResize
        /// BUG-016: the content offset was written directly with a forced layout; its absence during a blank says the ladder believed it had already succeeded.
        case offsetSettle
        /// The trailing scroll after a burst of content growth, once per burst.
        case followSettle
    }

    static func scroll(_ site: Site, isNearBottom: Bool) {
        switch site {
        case .followTail:
            log.debug("scroll site=followTail nearBottom=\(isNearBottom, privacy: .public)")
        default:
            log.notice("""
                scroll site=\(site.rawValue, privacy: .public) \
                nearBottom=\(isNearBottom, privacy: .public)
                """)
            TranscriptScrollBuffer.shared.append(
                "scroll site=\(site.rawValue) nearBottom=\(isNearBottom)"
            )
        }
    }

    /// Every chrome transition, including the ones that earn no scroll — `height=no` is exactly as diagnostic as `height=yes`.
    static func chromeTransition(
        from old: String,
        to new: String,
        changesHeight: Bool,
        isNearBottom: Bool,
        armed: Bool
    ) {
        log.notice("""
            chrome \(old, privacy: .public) -> \(new, privacy: .public) \
            height=\(changesHeight ? "yes" : "no", privacy: .public) \
            nearBottom=\(isNearBottom, privacy: .public) \
            armed=\(armed ? "yes" : "no", privacy: .public)
            """)
        TranscriptScrollBuffer.shared.append("""
            chrome \(old) -> \(new) height=\(changesHeight ? "yes" : "no") \
            nearBottom=\(isNearBottom) armed=\(armed ? "yes" : "no")
            """)
    }

    /// BUG-016. Every container-height change the transcript noticed, including the ones that earn no placement.
    /// `armed=no` beside `tail=yes` means the chrome path already owns this change and this one stood down.
    static func containerHeight(
        from old: CGFloat?,
        to new: CGFloat,
        wasAtTail: Bool,
        armed: Bool
    ) {
        let before = old.map { String(format: "%.0f", Double($0)) } ?? "-"
        let after = String(format: "%.0f", Double(new))
        log.notice("""
            height \(before, privacy: .public) -> \(after, privacy: .public) \
            tail=\(wasAtTail ? "yes" : "no", privacy: .public) \
            armed=\(armed ? "yes" : "no", privacy: .public)
            """)
    }

    /// BUG-016. The last rung ran, and whether there was a `UIScrollView` to receive it.
    /// `scrollView=MISSING` is a dead end: `EnclosingScrollViewReader`'s superview walk found nothing, nothing else retries, and the reader's only escape is the button.
    static func settle(reached: Bool, isNearBottom: Bool) {
        log.notice("""
            scroll site=offsetSettle \
            scrollView=\(reached ? "found" : "MISSING", privacy: .public) \
            nearBottom=\(isNearBottom, privacy: .public)
            """)
    }

    /// The status slot, which is not chrome: it renders inside the transcript's `LazyVStack`, so it changes the scroll view's content height rather than its frame.
    static func statusTransition(from old: String?, to new: String?) {
        let before = old?.isEmpty == false ? "shown" : "none"
        let after = new?.isEmpty == false ? "shown" : "none"
        guard before != after else { return }
        log.notice("status \(before, privacy: .public) -> \(after, privacy: .public)")
        TranscriptScrollBuffer.shared.append("status \(before) -> \(after)")
    }
}

extension TranscriptScroll.Chrome {
    /// A five-character fingerprint — todos, agents, notice, error, prompt — so a transition reads as `T-N--` -> `-AN--` at a glance.
    var logSignature: String {
        String([
            hasTodos ? "T" : "-",
            hasAgents ? "A" : "-",
            hasNotice ? "N" : "-",
            hasError ? "E" : "-",
            hasBlockingPrompt ? "P" : "-",
        ])
    }
}

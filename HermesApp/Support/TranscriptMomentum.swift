import SwiftUI
import UIKit

/// BUG-051. The transcript's own momentum, and the one object that can stop it: `scrollTo` places content but does not cancel a scroll already in flight.
/// Never an animated scroll — BUG-009 and BUG-016 established that an animated scroll drive inside this transcript is the lockup mechanism.
/// If the enclosing scroll view is never found, every method here is a no-op and nothing in the transcript depends on it succeeding.
@MainActor
final class TranscriptMomentum {
    /// The scroll view that owns the transcript's momentum, once `EnclosingScrollViewReader` has found it; weak, because the view hierarchy owns it.
    weak var scrollView: UIScrollView?

    init() {}

    /// Freeze the scroll view where it is, so the discrete placement that follows is not superseded by an in-flight deceleration, returning whether anything was actually stopped.
    @discardableResult
    func halt() -> Bool {
        guard let scrollView else { return false }
        guard Self.shouldHalt(
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating
        ) else { return false }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        return true
    }

    // MARK: BUG-122 — keeping the reader's place across a reveal

    /// The bottom sentinel's edge as it stood when a reveal was asked for, held until the reading that follows the reveal arrives.
    /// Deliberately not a `@State` in `ChatView`: the other half arrives in `onPreferenceChange`, whose closure is captured from a body evaluation, and a reference type is read when it is called.
    private var revealSentinel: CGFloat?

    /// Arm the correction, with the sentinel reading taken before the rows are added.
    func armReveal(sentinelBottom: CGFloat) { revealSentinel = sentinelBottom }

    /// The other half: the first sentinel reading after the rows are added, returning whether the offset was corrected.
    /// The sentinel reports its bottom edge in the scroll view's own coordinate space, so content inserted above the reader moves it down by exactly the height inserted.
    @discardableResult
    func absorbReveal(sentinelBottom: CGFloat) -> Bool {
        guard let before = revealSentinel else { return false }
        revealSentinel = nil
        guard let shift = Self.revealShift(before: before, after: sentinelBottom),
              let scrollView else { return false }
        // Deliberately unclamped: `contentSize` may not have caught up with the layout that produced the reading, so clamping against it is the one way to get this wrong.
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y + shift),
            animated: false
        )
        return true
    }

    /// How far the content offset has to move so a reveal does not move the reader: the distance the bottom sentinel travelled across it.
    /// Zero is the transcript's spelling of unreported, so a reading that never happened decides nothing, and neither does a sentinel that did not move down.
    nonisolated static func revealShift(before: CGFloat, after: CGFloat) -> CGFloat? {
        guard before != 0, after != 0 else { return nil }
        let shift = after - before
        return shift > 0 ? shift : nil
    }

    /// `TranscriptScrollReading`, taken now.
    var reading: TranscriptScrollReading {
        guard let scrollView else { return .unavailable }
        return Self.reading(
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating,
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
    }

    /// How far from the computed bottom still counts as at the bottom, because a scroll view just placed there sits a sub-pixel fraction away on a 3x screen.
    nonisolated static var atBottomTolerance: CGFloat { 1 }

    /// The judgement half of `reading`, separated from the UIKit reads so the arithmetic can be exercised without a scroll view.
    nonisolated static func reading(
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool,
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> TranscriptScrollReading {
        let bottom = bottomOffset(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        return TranscriptScrollReading(
            isTouching: isUserDriving(
                isTracking: isTracking, isDragging: isDragging, isDecelerating: isDecelerating
            ),
            movedOffset: movedOffset(isDragging: isDragging, isDecelerating: isDecelerating),
            isAtBottom: contentOffsetY >= bottom - atBottomTolerance,
            isAvailable: true
        )
    }

    /// Did the reader move the content offset themselves? Deliberately not `isTracking`, because a finger resting on the transcript during a long press moves nothing (BUG-016).
    nonisolated static func movedOffset(isDragging: Bool, isDecelerating: Bool) -> Bool {
        isDragging || isDecelerating
    }

    /// BUG-016. The last rung of the placement ladder, and the only one that is not a `scrollTo`: a `scrollTo` at the bottom sentinel resolves against the `LazyVStack`'s estimated height, which can be nowhere.
    /// Writing `contentOffset` and forcing a layout pass replaces the estimate with a measurement, whether the belief was short or long.
    /// Returns whether there was a scroll view to do it to; a `false` is the end of the line, because nothing else retries.
    @discardableResult
    func settleAtBottom() -> Bool {
        guard let scrollView else { return false }
        let target = Self.bottomOffset(
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: target),
            animated: false
        )
        // `setContentOffset` only marks the scroll view as needing layout; this makes the pass happen before the caller's follow-up `scrollTo` reads the geometry.
        scrollView.layoutIfNeeded()
        return true
    }

    /// Where the bottom of a `UIScrollView`'s content sits, in its own offset space, given what it currently believes about itself.
    /// `max` of the two ends is the honest answer for both: a short transcript asks to be pinned at its top rather than dragged below itself.
    nonisolated static func bottomOffset(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let bottom = contentHeight + bottomInset - viewportHeight
        let top = -topInset
        return max(top, bottom)
    }

    /// Is a finger — or its momentum — on the transcript right now? All three phases count, which is right for the live veto and wrong for the historical classification.
    nonisolated static func isUserDriving(
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool
    ) -> Bool {
        isTracking || isDragging || isDecelerating
    }

    /// The judgement half, separated from the UIKit call so it can be exercised without a scroll view.
    /// Both phases count: a finger still down owns the offset, and a placement issued under it is overwritten by the next touch delivery.
    nonisolated static func shouldHalt(isDragging: Bool, isDecelerating: Bool) -> Bool {
        isDragging || isDecelerating
    }
}

/// Hands `TranscriptMomentum` the `UIScrollView` it is standing next to, by walking its own superview chain once when it enters a window.
/// It must be planted in the scroll view's content, not in an `.overlay`: an overlay is a sibling layered above rather than a child, and the chain never reaches the scroll view.
/// Finding nothing is graceful — `scrollView` stays nil and every method on it is a no-op.
struct EnclosingScrollViewReader: UIViewRepresentable {
    let momentum: TranscriptMomentum

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(momentum: momentum)
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.momentum = momentum
    }

    /// Deliberately inert — no size, no drawing, hit testing off — so it does not compete with the tap gestures that dismiss the keyboard (BUG-012).
    final class ProbeView: UIView {
        var momentum: TranscriptMomentum

        init(momentum: TranscriptMomentum) {
            self.momentum = momentum
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isOpaque = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("EnclosingScrollViewReader.ProbeView is never built from a nib")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var candidate: UIView? = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    momentum.scrollView = scrollView
                    return
                }
                candidate = view.superview
            }
        }
    }
}

// MARK: - What the transcript's scroll view can say about itself

/// BUG-016. Everything the transcript's scroll view can say about itself, in one value, taken at one instant.
/// The three facts are deliberately separate: a finger being present is the right test for a live veto, having moved the offset is the right test for "did they leave the tail on purpose", and being at the bottom outranks both because it is not an inference.
/// `isAvailable` is the one easiest to get backwards: when no scroll view was found none of the three is a measurement, so a caller that reads "not driving" as a measured no would re-place every reader forever.
struct TranscriptScrollReading: Equatable {
    /// A finger is on the transcript, or its momentum still is.
    var isTouching: Bool
    /// The reader actually moved the content offset; a touch that never became a drag is not this.
    var movedOffset: Bool
    /// The content offset is at the bottom of the content, within a point.
    var isAtBottom: Bool
    /// Whether any of the above is a measurement rather than a default.
    var isAvailable: Bool

    init(
        isTouching: Bool = false,
        movedOffset: Bool = false,
        isAtBottom: Bool = false,
        isAvailable: Bool = true
    ) {
        self.isTouching = isTouching
        self.movedOffset = movedOffset
        self.isAtBottom = isAtBottom
        self.isAvailable = isAvailable
    }

    /// No scroll view was ever found; says nothing, and is not evidence of anything.
    static let unavailable = TranscriptScrollReading(
        isTouching: false, movedOffset: false, isAtBottom: false, isAvailable: false
    )
}

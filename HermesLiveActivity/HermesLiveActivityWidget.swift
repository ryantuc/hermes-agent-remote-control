import ActivityKit
import AppIntents
import HermesServeKit
import SwiftUI
import WidgetKit

/// The Lock Screen card and the Dynamic Island.
///
/// The Lock Screen card never shows the command, the same rule `ApprovalNotifications` follows; the island's expanded presentation does, and only when the whole command fits.
///
/// A widget process has no `TimelineView`, no `ScrollView`, no gesture and no continuously running animation, so the elapsed time is a system-ticked `Text(_:style:.timer)` and the pulse is a symbol effect.
struct HermesLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            // One activity feeds both surfaces with no API to opt out of one, so "off" is a card that gives nothing away rather than no card.
            Group {
                if context.state.showsOnLockScreen {
                    LockScreenCard(attributes: context.attributes, state: context.state, isStale: context.isStale)
                } else {
                    ReducedLockScreenCard(attributes: context.attributes, state: context.state, isStale: context.isStale)
                }
            }
            .padding(Space.s6)
            .activityBackgroundTint(tokens(for: context.attributes).canvas)
            .activitySystemActionForegroundColor(tokens(for: context.attributes).text1)
        } dynamicIsland: { context in
            let t = tokens(for: context.attributes)
            let state = context.state
            let stale = context.isStale
            // Each region is emptied rather than the island suppressed, because a live `Activity` cannot suppress it and two `DynamicIsland` literals are two types one configuration cannot both return.
            let showsIsland = state.showsInIsland

            return DynamicIsland {
                // The padding is not decoration: the expanded leading and trailing regions run up to the island's rounded edge and content flush against it is clipped, not truncated.
                DynamicIslandExpandedRegion(.leading) {
                    if showsIsland {
                        Text(state.title)
                            .font(HermesFont.calloutStrong)
                            .foregroundStyle(t.text1)
                            .lineLimit(1)
                            .padding(.leading, Space.s5)
                            .environment(\.hermes, t)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if showsIsland {
                        ElapsedLabel(startedAt: state.startedAt, endedAt: state.endedAt)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                            .padding(.trailing, Space.s5)
                            .environment(\.hermes, t)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if showsIsland {
                        ExpandedBottom(attributes: context.attributes, state: state, isStale: stale)
                            .environment(\.hermes, t)
                    }
                }
            } compactLeading: {
                if showsIsland {
                    HStack(spacing: Space.s2) {
                        PulseDot(isBusy: state.isBusy, needsInput: state.isWaitingOnPerson, isStale: stale)
                        ProgressCount(state: state)
                            .font(HermesFont.footnote)
                            // `text1`, not the `text2` this would take elsewhere: the island is always drawn on black, and the ramp's lower rungs are alphas mixed for the app's own canvas.
                            .foregroundStyle(t.text1)
                    }
                    .environment(\.hermes, t)
                }
            } compactTrailing: {
                // Deliberately empty: a running timer here grows the compact region until it pushes the clock, wifi and signal off the status bar for the whole turn.
                EmptyView()
            } minimal: {
                if showsIsland {
                    PulseDot(isBusy: state.isBusy, needsInput: state.isWaitingOnPerson, isStale: stale)
                        .environment(\.hermes, t)
                }
            }
            .widgetURL(HermesActivityLink.chat(sessionKey: context.attributes.sessionKey))
        }
    }

    /// The widget process cannot reach the app's `Theme`, so the skin travels in the attributes and the token derivation is compiled in.
    private func tokens(for attributes: HermesActivityAttributes) -> HermesTokens {
        let seed = attributes.skin
        let skin = HermesSkin(
            fg: RGBA(hex: seed.fg),
            accent: RGBA(hex: seed.accent),
            bg: RGBA(hex: seed.bg),
            card: RGBA(hex: seed.card)
        )
        return HermesTokens(skin: skin, polarity: seed.isDark ? .dark : .light)
    }
}

// MARK: - Lock Screen

/// Flat: whitespace and one hairline-thin bar, because the system already draws the container.
private struct LockScreenCard: View {
    let attributes: HermesActivityAttributes
    let state: LiveActivitySnapshot
    /// ActivityKit's verdict that nothing has updated this card for longer than `staleWindow`.
    let isStale: Bool

    private var t: HermesTokens {
        let seed = attributes.skin
        return HermesTokens(
            skin: HermesSkin(
                fg: RGBA(hex: seed.fg),
                accent: RGBA(hex: seed.accent),
                bg: RGBA(hex: seed.bg),
                card: RGBA(hex: seed.card)
            ),
            polarity: seed.isDark ? .dark : .light
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                PulseDot(isBusy: state.isBusy, needsInput: state.isWaitingOnPerson, isStale: isStale)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(HermesFont.calloutStrong)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                    // `attributes.backendName` is no longer rendered but stays on the struct: `ActivityAttributes` is archived with every in-flight activity, so dropping a stored property can fail the decode on a card that outlived the update.
                    ProgressLabel(state: state, isStale: isStale)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }

                Spacer(minLength: Space.s4)

                ElapsedLabel(startedAt: state.startedAt, endedAt: state.endedAt)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text2)
            }

            if state.hasApproval {
                // No command text here: a Live Activity is lock-screen glass.
                Text("Waiting for your approval")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.warn)
                    .lineLimit(1)
                HStack(spacing: Space.s4) {
                    Button(intent: DenyApprovalFromActivityIntent(token: state.approvalToken, session: attributes.sessionKey)) {
                        Text("Deny")
                            .font(HermesFont.footnote)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .tint(t.danger)
                    Link(destination: HermesActivityLink.chat(sessionKey: attributes.sessionKey)) {
                        Text("Review in Hermes")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text1)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(t.fill3, in: Capsule())
                    }
                }
            } else if let parked = state.parkedQuestion, !isStale {
                // BUG-062 B. The kind of wait and nothing else, and a link rather than an answer: a question is answered in the app. A stale card makes no claim that the question is still open.
                Text(parked.line)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.warn)
                    .lineLimit(1)
                Link(destination: HermesActivityLink.chat(sessionKey: attributes.sessionKey)) {
                    Text(parked.linkTitle)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text1)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(t.fill3, in: Capsule())
                }
            } else {
                ProgressBar(completed: state.toolsCompleted, total: state.toolsTotal)
            }
        }
        .environment(\.hermes, t)
    }
}

/// The Lock Screen card with its Lock Screen switch off.
///
/// It reaches no session content by construction: the only text it can produce is `ParkedQuestion.reducedLine`, which returns a constant for a parked question and otherwise `LiveActivityDerivation.reducedLine`, one of four constants with no path from the snapshot's strings.
///
/// It exists because ActivityKit will not let a live activity drop one of its two presentations.
private struct ReducedLockScreenCard: View {
    let attributes: HermesActivityAttributes
    let state: LiveActivitySnapshot
    let isStale: Bool

    private var t: HermesTokens {
        let seed = attributes.skin
        return HermesTokens(
            skin: HermesSkin(
                fg: RGBA(hex: seed.fg),
                accent: RGBA(hex: seed.accent),
                bg: RGBA(hex: seed.bg),
                card: RGBA(hex: seed.card)
            ),
            polarity: seed.isDark ? .dark : .light
        )
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            PulseDot(isBusy: state.isBusy, needsInput: state.isWaitingOnPerson, isStale: isStale)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

            Text("Hermes")
                .font(HermesFont.calloutStrong)
                .foregroundStyle(t.text1)
                .lineLimit(1)

            Spacer(minLength: Space.s4)

            Text(ParkedQuestion.reducedLine(for: state, isStale: isStale))
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
                .lineLimit(1)
        }
        .environment(\.hermes, t)
    }
}

// MARK: - Dynamic Island, expanded

private struct ExpandedBottom: View {
    @Environment(\.hermes) private var t
    let attributes: HermesActivityAttributes
    let state: LiveActivitySnapshot
    let isStale: Bool

    var body: some View {
        if state.hasApproval {
            approval
        } else if let parked = state.parkedQuestion, !isStale {
            parkedQuestion(parked)
        } else {
            // One rung brighter than the same label on the Lock Screen card, because the island is black.
            VStack(alignment: .leading, spacing: Space.s4) {
                ProgressLabel(state: state, isStale: isStale)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProgressBar(completed: state.toolsCompleted, total: state.toolsTotal)
            }
        }
    }

    /// The command in `HermesFont.code`, then the two answers, but only when the whole command is on screen.
    @ViewBuilder
    private var approval: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if state.approvalFitsIsland {
                Text(state.approvalCommand)
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
                    .lineLimit(IslandCommandBudget.lines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s4)
                    .enclosure(.danger)
            } else {
                // The read gate: no Approve here, because on a surface with no scroller there is no way to have read this.
                Text(state.approvalDescription.isEmpty ? "A command is waiting" : state.approvalDescription)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text2)
                    .lineLimit(2)
                Text("Too long to show here — open Hermes to read it.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.warn)
                    .lineLimit(2)
            }

            HStack(spacing: Space.s4) {
                Button(intent: DenyApprovalFromActivityIntent(token: state.approvalToken, session: attributes.sessionKey)) {
                    Text("Deny")
                        .font(HermesFont.calloutStrong)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .tint(t.danger)

                if state.approvalFitsIsland {
                    Button(intent: ApproveApprovalFromActivityIntent(token: state.approvalToken, session: attributes.sessionKey)) {
                        Text("Approve")
                            .font(HermesFont.calloutStrong)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .tint(t.action)
                } else {
                    // A `Link` gets no button styling, so it is dressed as a capsule to read as the peer of the `Button(intent:)` beside it.
                    Link(destination: HermesActivityLink.chat(sessionKey: attributes.sessionKey)) {
                        Text("Open Hermes")
                            .font(HermesFont.calloutStrong)
                            .foregroundStyle(t.text1)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(t.fill3, in: Capsule())
                    }
                }
            }
        }
    }

    /// BUG-062 B. The wait, named by kind, and the one way to answer it: open the chat. No intent buttons, because the island's only answers are an approval's.
    private func parkedQuestion(_ parked: ParkedQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(parked.line)
                .font(HermesFont.subhead)
                .foregroundStyle(t.warn)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: HermesActivityLink.chat(sessionKey: attributes.sessionKey)) {
                Text(parked.linkTitle)
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(t.fill3, in: Capsule())
            }
        }
    }

}

// MARK: - Parts

/// A widget process runs no `repeatForever` animation, so the dot is legible as a state with no motion at all: warn while a person is needed, action while working, text-4 when idle.
private struct PulseDot: View {
    @Environment(\.hermes) private var t
    let isBusy: Bool
    let needsInput: Bool
    /// A stale card goes inert and grey rather than keep claiming a running turn.
    var isStale: Bool = false

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(colour)
            .symbolEffect(.pulse, options: .repeating, isActive: (isBusy || needsInput) && !isStale)
            .accessibilityLabel(label)
    }

    private var colour: Color {
        if isStale { return t.text4 }
        if needsInput { return t.warn }
        return isBusy ? t.action : t.text4
    }

    private var label: String {
        if isStale { return "No longer updating" }
        return needsInput ? "Waiting for you" : (isBusy ? "Running" : "Idle")
    }
}

/// `7/12`, absent entirely before the first tool call.
///
/// The compact island region only, and a bare counter: anything wider pushes the clock and signal bars off the status bar.
private struct ProgressCount: View {
    let state: LiveActivitySnapshot

    var body: some View {
        if state.toolsTotal > 0 {
            Text("\(state.toolsCompleted)/\(state.toolsTotal)")
                .hermesNumeric()
        }
    }
}

/// `7/12`, or the word for a turn that is over or stale.
///
/// The rule lives in `LiveActivityDerivation.progressLabel` rather than here, because a widget body cannot be asserted on.
private struct ProgressLabel: View {
    let state: LiveActivitySnapshot
    let isStale: Bool

    private var text: String {
        LiveActivityDerivation.progressLabel(for: state, isStale: isStale)
    }

    var body: some View {
        if !text.isEmpty {
            // `monospacedDigit` so the counter does not shuffle the layout as it climbs.
            Text(text)
                .hermesNumeric()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Counts up from the turn's start without a single update from the app.
///
/// `width` pins the label where there is room for it so the digits do not shuffle the layout as they tick; in a compact region pass nil.
private struct ElapsedLabel: View {
    let startedAt: Date
    /// When the turn ended, if it has; a bounded `timerInterval` freezes the digits so a finished card does not keep counting.
    var endedAt: Date? = nil
    var width: CGFloat? = 52

    var body: some View {
        timeText
            .hermesNumeric()
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }

    @ViewBuilder
    private var timeText: some View {
        if let endedAt {
            // `max` because a clock skew putting the end before the start is an invalid range and crashes the widget.
            Text(timerInterval: startedAt...max(startedAt, endedAt), countsDown: false)
        } else {
            Text(startedAt, style: .timer)
        }
    }
}

/// The thin progress bar: two points tall, a rule and not a control.
private struct ProgressBar: View {
    @Environment(\.hermes) private var t
    let completed: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(t.stroke3)
                Rectangle()
                    .fill(t.action)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, CGFloat(completed) / CGFloat(total))
    }
}

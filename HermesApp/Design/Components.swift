import SwiftUI

// Additive primitives built out of the existing tokens only: nothing here introduces a colour, radius, duration or type step the design system does not already have.

/// Uppercase caption label with an optional trailing count and caret; with a caret it is a full-width button.
///
/// The static header is 38 pt and the button form 44 pt, because a target may not sit under the accessibility floor.
/// The choice control for a closed set of two or three short options, mirroring the desktop's SegmentedControl.
public struct SegmentedRow<Option: Hashable>: View {
    @Environment(\.hermes) private var t

    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    public init(options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    guard !isSelected else { return }
                    selection = option
                    HapticFeedback.selection()
                } label: {
                    Text(label(option))
                        .font(isSelected ? HermesFont.calloutStrong : HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .frame(maxWidth: .infinity, minHeight: Hit.min - 4)
                        .background(
                            isSelected ? t.fill3 : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label(option))\(isSelected ? ", selected" : "")")
            }
        }
        .padding(2)
        .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A `FlatRow` with a 44 x 26 track; the whole row is the target, not just the switch.
public struct SwitchRow: View {
    @Environment(\.hermes) private var t

    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    public init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
            HapticFeedback.selection()
        } label: {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                    if let subtitle {
                        Text(subtitle)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                Capsule()
                    .fill(isOn ? t.action : t.fill3)
                    .frame(width: 44, height: 26)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(isOn ? t.actionInk : t.text3)
                            .frame(width: 22, height: 22)
                            .padding(2)
                    }
                    .animation(Motion.quick, value: isOn)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A capped, two-axis scrolling monospace region: content never wraps, the page never scrolls sideways because the horizontal axis lives in here, and output past the line budget is head-and-tail elided behind a full-screen reader.
public struct CodeScroller: View {
    @Environment(\.hermes) private var t

    let text: String
    var maxHeight: CGFloat = 320
    var lineBudget: Int = 2_000
    var ink: Color?

    @State private var showingReader = false
    /// Sizes the viewport without a measurement pass, which keeps a one-line command one line tall.
    @ScaledMetric(relativeTo: .caption) private var estimatedLineHeight: CGFloat = 17

    public init(text: String, maxHeight: CGFloat = 320, lineBudget: Int = 2_000, ink: Color? = nil) {
        self.text = text
        self.maxHeight = maxHeight
        self.lineBudget = lineBudget
        self.ink = ink
    }

    public var body: some View {
        let lines = text.components(separatedBy: "\n")
        let shownLines = min(lines.count, lineBudget + 3)
        let boxHeight = min(CGFloat(shownLines) * estimatedLineHeight + Space.s3, maxHeight)
        VStack(alignment: .leading, spacing: Space.s3) {
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(displayText(lines))
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(ink ?? t.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .frame(height: boxHeight)

            if lines.count > lineBudget {
                Button {
                    showingReader = true
                } label: {
                    Text("Show all \(lines.count) lines")
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.action)
                        .frame(minHeight: Hit.min, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(isPresented: $showingReader) {
            FullScreenCodeReader(text: text)
        }
    }

    /// Head and tail past the budget, with the elision row saying how much is hidden.
    private func displayText(_ lines: [String]) -> String {
        guard lines.count > lineBudget else { return text }
        let half = lineBudget / 2
        let head = lines.prefix(half)
        let tail = lines.suffix(half)
        let hidden = lines.count - half * 2
        return (head + ["", "⋯ \(hidden) lines elided ⋯", ""] + tail).joined(separator: "\n")
    }
}

/// The full-screen reader: monospace, filterable, shareable, and lazy per line so a very long log stays scrollable.
public struct FullScreenCodeReader: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss

    let text: String
    @State private var filter = ""

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        NavigationStack {
            // Nested axes, not a combined-axis ScrollView, which centres short content and sizes a lazy stack to the viewport so wide lines fall outside the scroll extent.
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(displayText)
                        .font(HermesFont.codeSmall)
                        .foregroundStyle(t.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(Space.s5)
                }
            }
            .background(t.canvas)
            .navigationTitle("Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(t.action)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(t.text1)
                    }
                    .accessibilityLabel("Share output")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: Space.s3) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(t.text4)
                    TextField("Filter lines", text: $filter)
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .frame(minHeight: Hit.min)
                .padding(.horizontal, Space.s6)
                .background(t.canvas)
                .hairline()
            }
            // Outside the filter row's inset, so the plane below iOS 26 ends where the bar ends.
            .hermesTopBar()
        }
    }

    private var displayText: String {
        let lines = filteredLines
        // Preserve empty lines as a single space so the row still paints.
        return lines.map { $0.isEmpty ? " " : $0 }.joined(separator: "\n")
    }

    private var filteredLines: [String] {
        let lines = text.components(separatedBy: "\n")
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// The send contract's status slot, never empty between send and first token; the stalled form escalates to a two-button recovery row.
public struct StatusLine: View {
    @Environment(\.hermes) private var t

    public enum Phase: Equatable {
        case status(String)
        /// The 8 s honesty threshold fired: no acknowledgement from the host.
        case stalled(host: String)
    }

    let phase: Phase
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?

    public init(phase: Phase, onRetry: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.phase = phase
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    public var body: some View {
        switch phase {
        case .status(let text):
            HStack(spacing: Space.s3) {
                PulsingDot(color: t.warn, size: 6)
                Text(text)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
            .frame(minHeight: 20, alignment: .leading)
            .accessibilityElement(children: .combine)

        case .stalled(let host):
            VStack(alignment: .leading, spacing: Space.s4) {
                Text("No acknowledgement from \(host)")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                HStack(spacing: Space.s4) {
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    if let onCancel {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: 280)
            }
        }
    }
}

public struct SectionHeader: View {
    @Environment(\.hermes) private var t

    let title: String
    var count: Int?
    /// A short free-form fact beside the title, typically a progress fraction, for headers that need to say more than the bare integer `count` can (BUG-014).
    ///
    /// Height-neutral by construction: it rides the line the title is on, and both branches pin that line.
    var detail: String?
    /// Free text after `detail`, typically what the group is working on.
    ///
    /// Separate from `detail` because that is tabular-numeral styled, and first to lose width so a long task truncates instead of squeezing out the title or the fraction.
    var note: String?
    /// Non-nil makes the header a collapse toggle.
    var isExpanded: Bool?
    var onToggle: (() -> Void)?

    public init(
        _ title: String,
        count: Int? = nil,
        detail: String? = nil,
        note: String? = nil,
        isExpanded: Bool? = nil,
        onToggle: (() -> Void)? = nil
    ) {
        self.title = title
        self.count = count
        self.detail = detail
        self.note = note
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    public var body: some View {
        if let isExpanded, let onToggle {
            Button(action: onToggle) {
                label(caret: isExpanded)
                    .frame(minHeight: Hit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
        } else {
            label(caret: nil)
                .frame(height: 38, alignment: .bottom)
                .padding(.bottom, Space.s2)
        }
    }

    private func label(caret: Bool?) -> some View {
        HStack(spacing: Space.s3) {
            if let caret {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t.text4)
                    .rotationEffect(.degrees(caret ? 90 : 0))
                    .animation(Motion.quick, value: caret)
                    .accessibilityHidden(true)
            }
            Text(title)
                .hermesCaption()
                .foregroundStyle(t.text3)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(HermesFont.footnote)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let note, !note.isEmpty {
                Text(note)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.s4)
            if let count {
                Text("\(count)")
                    .font(HermesFont.caption)
                    .hermesNumeric()
                    .foregroundStyle(t.text3)
            }
        }
        .padding(.horizontal, Space.s6)
    }
}

// MARK: - TabRow

/// The segmented tab bar: `SegmentedRow` geometry that scrolls when the labels overflow, with the caller owning the persisted selection.
enum TabSegmentWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

public struct TabRow: View {
    @Environment(\.hermes) private var t

    let tabs: [String]
    let label: (String) -> String
    @Binding var selection: String

    public init(tabs: [String], selection: Binding<String>, label: @escaping (String) -> String = { $0 }) {
        self.tabs = tabs
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        // BUG-023: `SegmentedRow` geometry when the labels fit, the scroller only when they overflow.
        ViewThatFits(in: .horizontal) {
            tabStack(flexible: true)
            ScrollView(.horizontal, showsIndicators: false) {
                tabStack(flexible: false)
            }
        }
        .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func tabStack(flexible: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let isSelected = tab == selection
                Button {
                    guard !isSelected else { return }
                    selection = tab
                    HapticFeedback.selection()
                } label: {
                    Text(label(tab))
                        .font(isSelected ? HermesFont.calloutStrong : HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .padding(.horizontal, flexible ? 0 : Space.s5)
                        .frame(
                            minWidth: flexible ? 0 : 72,
                            maxWidth: flexible ? .infinity : nil,
                            minHeight: Hit.min - 4
                        )
                        .background(
                            isSelected ? t.fill3 : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label(tab))\(isSelected ? ", selected" : "")")
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: TabSegmentWidthKey.self,
                        value: [tab: geo.size.width]
                    )
                })
            }
        }
        .padding(2)
    }
}

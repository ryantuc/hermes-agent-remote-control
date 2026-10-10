import HermesServeKit
import SwiftUI

/// A small read-only sheet behind the `⋯` nav-bar item, showing what
/// `SessionInfo` decodes: model, provider, effort, approval mode, `yolo`, cwd,
/// branch, personality and the contract version.
///
/// Every value is wrapped in the five-state contract, so a lazy resume shows em
/// dashes rather than blanks and a dropped connection greys the last-known
/// values rather than clearing them.
@MainActor
struct SessionSheetView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let model: ChatModel

    private var info: SessionInfo? { model.info }
    private var connected: Bool { app.connectionState.isOpen }
    private var lazy: Bool { info?.lazy ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s8) {
                    contextGroup

                    group("Agent") {
                        row("Model", info?.model ?? "")
                        row("Provider", info?.provider ?? "")
                        row("Reasoning effort", info?.reasoningEffort ?? "")
                    }

                    group("Session") {
                        row("Approval mode", info?.approvalMode ?? "")
                        row("YOLO", yoloValue)
                        row("Personality", info?.personality ?? "")
                    }

                    group("Workspace") {
                        row("Working directory", cwdValue)
                        row("Branch", info?.branch ?? "")
                    }

                    group("Protocol") {
                        row("Contract version", contractValue)
                    }
                }
                .padding(.vertical, Space.s6)
            }
            .background(t.canvas)
            .task { await refreshUsage() }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(t.action)
                }
            }
            .hermesTopBar()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
    }

    // MARK: Context ring

    private var contextGroup: some View {
        let yolo = info?.yolo ?? false
        return group("Context") {
            HStack(spacing: Space.s6) {
                ContextRing(fraction: model.usage?.contextFraction, danger: yolo)
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let usage = model.usage, usage.hasContext,
                       let used = usage.contextUsed, let max = usage.contextMax {
                        Text("\(used.formatted()) / \(max.formatted()) tokens")
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                            .hermesNumeric()
                    } else {
                        Text("Context usage appears after the first turn.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                    }
                    if yolo {
                        Text("YOLO is on — approvals are bypassed on this machine.")
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.danger)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s5)
        }
    }

    private func refreshUsage() async {
        guard let sessionID = model.runtimeSessionID, let configAPI = app.configAPI else { return }
        if let usage = try? await configAPI.usage(sessionID: sessionID) {
            model.usage = usage
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .hermesCaption()
                .foregroundStyle(t.text3)
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s3)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        FlatRow(showsHairline: false) {
            Text(label)
                .font(HermesFont.callout)
                .foregroundStyle(t.text2)
        } trailing: {
            ValueView(ValueState.of(value, connected: connected, lazy: lazy)) {
                Text(value)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var yoloValue: String {
        guard let info else { return "" }
        return info.yolo ? "On" : "Off"
    }

    private var cwdValue: String {
        guard let cwd = info?.cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    private var contractValue: String {
        guard let contract = info?.desktopContract, contract > 0 else { return "" }
        return String(contract)
    }
}

/// The context meter. A ring that fills with context used; `danger` recolours it
/// when `yolo` is on. An unknown fraction shows an em dash rather than an empty
/// ring — the five-state contract, applied to a meter.
@MainActor
private struct ContextRing: View {
    @Environment(\.hermes) private var t
    let fraction: Double?
    let danger: Bool

    private var ringColor: Color {
        if danger { return t.danger }
        guard let fraction else { return t.text4 }
        if fraction >= 0.9 { return t.danger }
        if fraction >= 0.75 { return t.warn }
        return t.action
    }

    var body: some View {
        ZStack {
            Circle().stroke(t.stroke3, lineWidth: 5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(HermesFont.footnote)
                    .hermesNumeric()
                    .foregroundStyle(t.text1)
            } else {
                Text(verbatim: "—")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel(fraction.map { "Context \(Int(($0 * 100).rounded())) percent used" } ?? "Context usage not reported")
    }
}

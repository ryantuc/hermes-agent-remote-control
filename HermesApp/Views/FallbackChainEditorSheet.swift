import HermesServeKit
import SwiftUI

/// The editor for `fallback_providers`: the chain in the order the backend tries it, dragged to reorder, swiped or minus-tapped to remove, and added to through the same picker the composer uses. Every change is written at once, the whole list each time, because the backend replaces a list rather than merging it.
@MainActor
struct FallbackChainEditorSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let row: SettingRowDescriptor

    @State private var entries: [FallbackEntry] = []
    @State private var loaded = false
    @State private var showingPicker = false

    private var store: SettingsStore { app.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let failure = store.writeFailures[row.key] {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }

            if let description = row.description {
                Text(description)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s4)
            }

            if entries.isEmpty {
                Text("No fallback models yet. If the main model fails, the turn fails with it.")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.vertical, Space.s4)
                Spacer(minLength: 0)
            } else {
                chainList
            }

            addButton
        }
        .background(t.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            entries = store.fallbackChain()
        }
        .sheet(isPresented: $showingPicker) {
            ModelEffortSheet(choosing: addPick)
        }
    }

    private var header: some View {
        HStack {
            Text(row.label)
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.text3)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s6)
        .padding(.bottom, Space.s4)
    }

    private var chainList: some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: Space.s4) {
                    Text("\(index + 1)")
                        .font(HermesFont.code)
                        .foregroundStyle(t.text4)
                        .frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(entry.pair.model)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.pair.provider)
                            .font(HermesFont.code)
                            .foregroundStyle(t.text3)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, Space.s2)
                .listRowBackground(t.canvas)
                .listRowInsets(EdgeInsets(top: 0, leading: Space.s6, bottom: 0, trailing: Space.s6))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index + 1): \(entry.pair.displayText)")
            }
            .onMove { from, to in
                entries.move(fromOffsets: from, toOffset: to)
                commit()
            }
            .onDelete { offsets in
                entries.remove(atOffsets: offsets)
                commit()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(t.canvas)
        .environment(\.editMode, .constant(.active))
    }

    private var addButton: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add a fallback model")
                    .font(HermesFont.callout)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .hairline(.top)
    }

    /// The picker in its add-to-the-chain mode: no current choice, no inherit row, a typed `provider/model` allowed.
    private var addPick: ModelSettingPick {
        ModelSettingPick(
            title: "Add a fallback model",
            current: ModelPair(provider: "", model: ""),
            typedHint: "Type it as provider/model.",
            onPick: { choice, _ in
                switch choice {
                case .catalogue(let pair):
                    return await append(pair)
                case .typed(let text):
                    let pair = ModelPair.parsing(text)
                    guard !pair.provider.isEmpty, !pair.model.isEmpty else {
                        return .failed(ModelSettingTarget.needsProviderMessage)
                    }
                    return await append(pair)
                case .inherit:
                    return .done
                }
            }
        )
    }

    private func append(_ pair: ModelPair) async -> ModelPickOutcome {
        entries.append(FallbackEntry(pair: pair))
        await store.setFallbackChain(entries)
        if let failure = store.writeFailures[row.key] {
            entries = store.fallbackChain()
            return .failed(failure)
        }
        return .done
    }

    private func commit() {
        let write = store.queueFallbackChain(entries)
        Task {
            await write.value
            // A refused write leaves the store holding what the backend has; re-seed so the list shows that rather than the refused chain.
            if store.writeFailures[row.key] != nil {
                entries = store.fallbackChain()
            }
        }
    }
}

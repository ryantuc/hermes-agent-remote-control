import HermesServeKit
import SwiftUI

/// One descriptor-driven settings screen: flat
/// rows, hairlines, no inset tables. A config-backed row renders only while
/// its key is in the document — a missing key removes the row, never
/// disables it. Writes paint first and roll back visibly (the failed row
/// carries its error in `danger` until the next attempt).
@MainActor
struct SettingsDetailView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app

    let screen: SettingsScreenDescriptor

    /// The row whose editor sheet is up (text / number / options / list).
    @State private var editing: SettingRowDescriptor?
    /// A destructive segment value awaiting its hold (approvals → off).
    @State private var armedHold: (key: String, value: String)?

    private var store: SettingsStore { app.settings }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = store.loadError {
                    loadErrorBlock(error)
                } else if store.document == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.s10)
                } else {
                    ForEach(screen.sections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle(screen.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
        .task { await store.loadIfNeeded() }
        .sheet(item: $editing) { row in
            SettingEditorSheet(row: row)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSectionDescriptor) -> some View {
        let rows = visibleRows(section)
        if !rows.isEmpty {
            if let header = section.header {
                SectionHeader(header)
                    .padding(.top, Space.s6)
            }
            ForEach(rows) { row in
                rowView(row)
            }
        }
    }

    private func visibleRows(_ section: SettingsSectionDescriptor) -> [SettingRowDescriptor] {
        section.rows.filter { row in
            guard !row.advanced || store.showAdvanced else { return false }
            // The ValueView removal contract: unreported keys drop their rows.
            // A row with an `unsetLabel` opts out (BUG-042): "the backend does
            // not report this" is exactly what that row exists to say, and
            // dropping it hides a setting the user can still change.
            if row.unsetLabel != nil { return true }
            return store.value(row.key) != nil
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: SettingRowDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row.kind {
            case .toggle:
                SwitchRow(
                    row.label,
                    subtitle: row.description,
                    isOn: Binding(
                        get: { store.boolValue(row.key) ?? false },
                        set: { newValue in Task { await store.set(row.key, to: .bool(newValue)) } }
                    )
                )
            case .segment(let options, let holdFor):
                segmentRow(row, options: options, holdFor: holdFor)
            case .options, .text, .number, .stringList:
                valueRow(row) { editing = row }
            case .display:
                valueRow(row, chevron: false, action: nil)
            }

            if let failure = store.writeFailures[row.key] {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }
        }
    }

    @ViewBuilder
    private func segmentRow(
        _ row: SettingRowDescriptor,
        options: [SettingOption],
        holdFor: Set<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(row.label)
                .font(HermesFont.callout)
                .foregroundStyle(t.text1)
            if let description = row.description {
                Text(description)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SegmentedRow(
                options: options.map(\.value),
                selection: Binding(
                    get: { store.stringValue(row.key) ?? options.first?.value ?? "" },
                    set: { newValue in
                        if holdFor.contains(newValue) {
                            // Destructive: arm the hold, do not commit the tap.
                            armedHold = (row.key, newValue)
                        } else {
                            armedHold = nil
                            Task { await store.set(row.key, to: .string(newValue)) }
                        }
                    }
                ),
                label: { value in options.first { $0.value == value }?.label ?? value }
            )
            if let armed = armedHold, armed.key == row.key {
                HoldToConfirmButton("Hold to switch to \(armed.value)") {
                    armedHold = nil
                    Task { await store.set(row.key, to: .string(armed.value)) }
                }
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .hairline()
    }

    @ViewBuilder
    private func valueRow(
        _ row: SettingRowDescriptor,
        chevron: Bool = true,
        action: (() -> Void)?
    ) -> some View {
        let content = FlatRow {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(row.label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                if let description = row.description {
                    Text(description)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            HStack(spacing: Space.s3) {
                ValueView(valueState) {
                    Text(displayValue(row))
                        .font(HermesFont.subhead)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.text4)
                }
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.label): \(displayValue(row))")
        } else {
            content
        }
    }

    private var valueState: ValueState {
        app.connectionState.isOpen ? .live : .stale
    }

    private func displayValue(_ row: SettingRowDescriptor) -> String {
        // BUG-042: `.number` is asked first, and with the *unresolved* value,
        // because the guard below turns an absent number into `""`.
        if case .number(let integer) = row.kind {
            return row.numberDisplay(store.value(row.key), integer: integer)
        }
        guard let value = store.value(row.key) else { return "" }
        switch row.kind {
        case .options(let staticOptions):
            let raw = value.coercedString ?? ""
            let options = staticOptions ?? store.schemaOptions(row.key)?.map { SettingOption($0) } ?? []
            return options.first { $0.value == raw }?.label ?? (raw.isEmpty ? "Default" : raw)
        case .stringList:
            let count = store.stringListValue(row.key)?.count ?? 0
            return count == 1 ? "1 entry" : "\(count) entries"
        case .display:
            if case .array(let items) = value {
                return items.count == 1 ? "1 entry" : "\(items.count) entries"
            }
            return value.coercedString ?? ""
        default:
            let raw = value.coercedString ?? ""
            return raw.isEmpty ? "None" : raw
        }
    }

    private func loadErrorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Couldn't load settings")
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
            Text(error)
                .font(HermesFont.subhead)
                .foregroundStyle(t.text3)
            Button("Try again") { Task { await store.reload() } }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .padding(Space.s6)
    }
}

// MARK: - Editor sheet

/// The one editor sheet for value rows: options list, free text, number, or
/// string list — decided by the row's kind. Single sheet, no handoffs (P10);
/// the write-failure slot sits above the content, never inside the scroll
/// (P18).
@MainActor
private struct SettingEditorSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let row: SettingRowDescriptor

    @State private var draftText = ""
    @State private var draftList: [String] = []
    @State private var newItem = ""
    @State private var loadedDraft = false
    /// Why the last Save wrote nothing (BUG-096 defect A). Distinct from
    /// `store.writeFailures`, which is why the *backend* refused a write that
    /// was actually attempted: this one never leaves the phone.
    @State private var editError: String?

    private var store: SettingsStore { app.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let failure = store.writeFailures[row.key] {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }

            switch row.kind {
            case .options(let staticOptions):
                optionsList(staticOptions)
            case .text(let placeholder):
                textEditor(placeholder: placeholder, numeric: false)
            case .number(let integer):
                textEditor(placeholder: "", numeric: true, integer: integer)
            case .stringList(let addPrompt):
                listEditor(addPrompt: addPrompt)
            default:
                EmptyView()
            }

            Spacer(minLength: 0)
        }
        .background(t.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        .onAppear { loadDraftIfNeeded() }
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

    private func loadDraftIfNeeded() {
        guard !loadedDraft else { return }
        loadedDraft = true
        switch row.kind {
        case .text, .number:
            if let value = store.value(row.key) {
                if case .number(let number) = value {
                    // BUG-109: `String(Int(number))` traps outside Int64.
                    draftText = SettingRowDescriptor.draftText(for: number)
                } else {
                    draftText = value.coercedString ?? ""
                }
            }
        case .stringList:
            draftList = store.stringListValue(row.key) ?? []
        default:
            break
        }
    }

    // MARK: Options

    private func optionsList(_ staticOptions: [SettingOption]?) -> some View {
        let options = staticOptions ?? store.schemaOptions(row.key)?.map { SettingOption($0) } ?? []
        let current = store.stringValue(row.key) ?? ""
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(options) { option in
                    Button {
                        Task {
                            await store.set(row.key, to: .string(option.value))
                            // BUG-096 defect B: dismiss only on success, the same
                            // contract as the text editor below.
                            if store.writeFailures[row.key] == nil { dismiss() }
                        }
                    } label: {
                        FlatRow {
                            Text(option.label)
                                .font(HermesFont.callout)
                                .foregroundStyle(t.text1)
                        } trailing: {
                            if option.value == current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(t.action)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.label)\(option.value == current ? ", selected" : "")")
                }
            }
        }
    }

    // MARK: Text / number

    private func textEditor(placeholder: String, numeric: Bool, integer: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            if let description = row.description {
                Text(description)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(placeholder, text: $draftText)
                .font(HermesFont.code)
                .foregroundStyle(t.text1)
                .keyboardType(numeric ? (integer ? .numberPad : .decimalPad) : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(Space.s4)
                .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .onChange(of: draftText) { _, newValue in
                    // BUG-109's length half: `.numberPad` caps nothing. The cap
                    // is above the backend's range so "Too large" stays reachable.
                    if numeric, newValue.count > SettingRowDescriptor.numericDraftMaxLength {
                        draftText = String(newValue.prefix(SettingRowDescriptor.numericDraftMaxLength))
                    }
                    // The complaint is about what was in the field when Save
                    // was pressed. Editing it makes the complaint stale.
                    if editError != nil { editError = nil }
                }

            if let editError {
                Text(editError)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Save") {
                // BUG-096 defect A: every reason Save can decline has a
                // sentence, and the sheet stays up carrying it.
                let outcome = row.editOutcome(draftText, numeric: numeric)
                guard case .value(let value) = outcome else {
                    editError = outcome.message
                    return
                }
                editError = nil
                Task {
                    await store.set(row.key, to: value)
                    if store.writeFailures[row.key] == nil { dismiss() }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, Space.s6)
    }

    // MARK: String list

    private func listEditor(addPrompt: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(draftList, id: \.self) { item in
                        FlatRow {
                            Text(item)
                                .font(HermesFont.code)
                                .foregroundStyle(t.text1)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } trailing: {
                            Button {
                                draftList.removeAll { $0 == item }
                                commitList()
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(t.text3)
                                    .frame(width: Hit.min, height: Hit.min)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(item)")
                        }
                    }
                }
            }

            HStack(spacing: Space.s3) {
                TextField(addPrompt, text: $newItem)
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(Space.s4)
                    .background(t.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .onSubmit { addItem() }
                Button {
                    addItem()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(t.text1)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Add")
            }
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)
        }
    }

    private func addItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !draftList.contains(trimmed) else { return }
        draftList.append(trimmed)
        newItem = ""
        commitList()
    }

    private func commitList() {
        Task {
            await store.set(row.key, to: .array(draftList.map { .string($0) }))
            // A failed write rolls the document back; re-seed the draft so
            // the sheet repaints the truth rather than the rejected list.
            if store.writeFailures[row.key] != nil {
                draftList = store.stringListValue(row.key) ?? draftList
            }
        }
    }
}

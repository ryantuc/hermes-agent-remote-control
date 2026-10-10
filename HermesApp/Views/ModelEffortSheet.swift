import HermesServeKit
import SwiftUI

/// What a pick means when the sheet is choosing a model for a setting rather than for a conversation.
enum ModelSettingChoice: Equatable {
    /// A row of the backend's catalogue, provider and all.
    case catalogue(ModelPair)
    /// A slug typed into the search field, for a model the catalogue does not list.
    case typed(String)
    /// Back to the main model.
    case inherit
}

enum ModelPickOutcome: Equatable {
    case done
    /// The backend wants a yes first; the sheet asks and calls again confirmed.
    case confirm(String)
    case failed(String)
}

/// The sheet's choose-for-a-setting mode: what it is choosing, what is chosen now, and where the pick goes.
struct ModelSettingPick {
    let title: String
    let current: ModelPair
    /// Whether the catalogue's own `is_current` flags name the current choice, which they do for the main model and for nothing else.
    var marksCatalogueCurrent = false
    /// The wording of the row that clears the setting, when clearing is on offer.
    var inheritLabel: String?
    var allowsTypedSlug = true
    var typedHint = "For a model the list does not have."
    let onPick: @MainActor (ModelSettingChoice, _ confirmed: Bool) async -> ModelPickOutcome
}

/// The one model drawer, built for a catalogue of hundreds of models across
/// many providers: sticky search, recents, one provider section expanded at a
/// time, and the effort bar pinned outside the scroll.
///
/// Opened from the composer it changes one conversation (a write during a
/// running turn comes back `deferred: true` → the composer pill enters
/// `ValueState.pending`); opened from Settings it chooses a model for a
/// setting and hands the pick back.
@MainActor
struct ModelEffortSheet: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Purpose {
        case conversation(ChatModel)
        case setting(ModelSettingPick)
    }

    private let purpose: Purpose

    /// `initialQuery` fills the search field on open, which is how `/model <text>` that matched nothing arrives.
    init(model: ChatModel, initialQuery: String = "") {
        purpose = .conversation(model)
        _query = State(initialValue: initialQuery)
    }

    init(choosing pick: ModelSettingPick) {
        purpose = .setting(pick)
    }

    private var model: ChatModel? {
        if case .conversation(let model) = purpose { return model }
        return nil
    }

    private var pick: ModelSettingPick? {
        if case .setting(let pick) = purpose { return pick }
        return nil
    }

    @State private var catalogue: ModelCatalogue?
    @State private var loadError: String?
    @State private var failure: String?
    @State private var expandedProvider: String?
    @State private var busySlug: String?
    @State private var busyChoice: ModelSettingChoice?
    @State private var busyEffort: ReasoningEffort?
    @State private var query = ""
    @State private var confirm: ExpensiveConfirm?

    private static let recentsKey = "hermes.models.recent"

    private struct ExpensiveConfirm: Identifiable {
        let message: String
        let proceed: () async -> Void
        var id: String { message }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pick { titleHeader(pick) }
            searchHeader
            content
            if model != nil { effortBar }
        }
        .background(t.canvas)
        .presentationDetents([.fraction(0.92)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.canvas)
        .task { await load() }
        .alert(item: $confirm) { pending in
            Alert(
                title: Text("Switch model?"),
                message: Text(pending.message),
                primaryButton: .default(Text("Switch anyway")) {
                    Task { await pending.proceed() }
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Sticky header

    private func titleHeader(_ pick: ModelSettingPick) -> some View {
        HStack(spacing: Space.s3) {
            Text(pick.title)
                .font(HermesFont.heading)
                .foregroundStyle(t.text1)
                .lineLimit(2)
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
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(t.text4)
                TextField("Search models and providers", text: $query)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(t.text4)
                            .frame(width: Hit.min, height: Hit.min)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .frame(minHeight: Hit.min)
            .padding(.horizontal, Space.s6)
            .hairline()

            // P18: the write-failure slot lives outside the scroll content.
            if let failure {
                Text(failure)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s6)
                    .padding(.vertical, Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hairline()
            }
        }
        .padding(.top, pick == nil ? Space.s5 : Space.s3)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let catalogue {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        if let pick, let inheritLabel = pick.inheritLabel {
                            inheritRow(inheritLabel, isCurrent: pick.current.isEmpty)
                        }
                        recentSection(catalogue)
                        ForEach(catalogue.providers) { provider in
                            providerSection(provider)
                        }
                    } else {
                        searchResults(catalogue)
                    }
                }
                .padding(.bottom, Space.s6)
            }
        } else if let loadError {
            VStack(spacing: Space.s5) {
                Text("Couldn't load models")
                    .font(HermesFont.heading)
                    .foregroundStyle(t.text1)
                Text(loadError)
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 220)
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Recent

    @ViewBuilder
    private func recentSection(_ catalogue: ModelCatalogue) -> some View {
        let rows = recentRows(catalogue)
        if !rows.isEmpty {
            SectionHeader("Recent")
            ForEach(rows, id: \.model.slug) { row in
                modelRow(row.model, provider: row.provider, showsProvider: true)
            }
        }
    }

    private func recentRows(_ catalogue: ModelCatalogue) -> [(model: ModelRow, provider: ProviderRow)] {
        let recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        return recents.compactMap { slug in
            for provider in catalogue.providers {
                if let model = provider.models.first(where: { $0.slug == slug }) {
                    return (model, provider)
                }
            }
            return nil
        }
    }

    // MARK: Providers

    private func providerSection(_ provider: ProviderRow) -> some View {
        let isExpanded = expandedProvider == provider.id
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                provider.name,
                count: provider.models.count,
                isExpanded: isExpanded,
                onToggle: {
                    withAnimation(Motion.quick) {
                        expandedProvider = isExpanded ? nil : provider.id
                    }
                }
            )
            if !provider.authenticated {
                Text(provider.warning.isEmpty ? "Not connected" : provider.warning)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.warn)
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s3)
            }
            if isExpanded {
                ForEach(provider.models) { entry in
                    modelRow(entry, provider: provider, showsProvider: false)
                }
            }
        }
        .hairline()
    }

    // MARK: Search — flattened, ranked

    private func searchResults(_ catalogue: ModelCatalogue) -> some View {
        let matches = rankedMatches(catalogue)
        let typed = query.trimmingCharacters(in: .whitespaces)
        return Group {
            if matches.isEmpty, pick?.allowsTypedSlug != true {
                Text("Nothing matches “\(query)”")
                    .font(HermesFont.subhead)
                    .foregroundStyle(t.text3)
                    .padding(Space.s6)
            } else {
                ForEach(matches, id: \.model.slug) { row in
                    modelRow(row.model, provider: row.provider, showsProvider: true)
                }
                if let pick, pick.allowsTypedSlug {
                    typedRow(typed, hint: pick.typedHint)
                }
            }
        }
    }

    private func rankedMatches(_ catalogue: ModelCatalogue) -> [(model: ModelRow, provider: ProviderRow)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var scored: [(model: ModelRow, provider: ProviderRow, score: Int)] = []
        for provider in catalogue.providers {
            let providerHit = provider.name.lowercased().contains(needle)
            for model in provider.models {
                let name = model.name.lowercased()
                let slug = model.slug.lowercased()
                let score: Int
                if name.hasPrefix(needle) || slug.hasPrefix(needle) { score = 0 }
                else if name.contains(needle) || slug.contains(needle) { score = 1 }
                else if providerHit { score = 2 }
                else { continue }
                scored.append((model, provider, score))
            }
        }
        return scored
            .sorted { ($0.score, $0.model.name) < ($1.score, $1.model.name) }
            .map { ($0.model, $0.provider) }
    }

    // MARK: Rows

    private func modelRow(_ entry: ModelRow, provider: ProviderRow, showsProvider: Bool) -> some View {
        Button {
            if pick != nil {
                Task { await choose(.catalogue(ModelPair(provider: provider.slug, model: entry.slug)), confirmed: false) }
            } else if provider.authenticated {
                Task { await selectModel(entry.slug, providerSlug: provider.slug, confirmExpensive: false) }
            } else if let model {
                // BUG-100: the Connect affordance carries the conversation's own
                // route, so Back from Backend settings returns to this chat.
                dismiss()
                app.requestRoute(
                    ComposerSettingsRoute.path(from: app.openRoute(for: model), to: .settingsBackend)
                )
            }
        } label: {
            FlatRow(showsHairline: false) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s3) {
                        Text(entry.name)
                            .font(HermesFont.callout)
                            .foregroundStyle(t.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if provider.supportsReasoning(entry.slug) {
                            Text(verbatim: "▮")
                                .font(HermesFont.caption)
                                .foregroundStyle(t.text4)
                                .accessibilityLabel("Supports reasoning")
                        }
                    }
                    Text(showsProvider ? "\(provider.name) · \(entry.slug)" : entry.slug)
                        .font(HermesFont.code)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } trailing: {
                if isBusy(entry, provider: provider) {
                    ProgressView().controlSize(.small)
                } else if pick == nil, !provider.authenticated {
                    Text("Connect")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.action)
                } else if isCurrent(entry, provider: provider) {
                    Image(systemName: "checkmark").foregroundStyle(t.action)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busySlug != nil || busyChoice != nil)
        .accessibilityLabel("\(entry.name)\(isCurrent(entry, provider: provider) ? ", selected" : "")")
    }

    private func inheritRow(_ label: String, isCurrent: Bool) -> some View {
        Button {
            Task { await choose(.inherit, confirmed: false) }
        } label: {
            FlatRow(showsHairline: false) {
                Text(label)
                    .font(HermesFont.callout)
                    .foregroundStyle(t.text1)
            } trailing: {
                if busyChoice == .inherit {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(t.action)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busyChoice != nil)
        .accessibilityLabel("\(label)\(isCurrent ? ", selected" : "")")
        .hairline()
    }

    private func typedRow(_ text: String, hint: String) -> some View {
        Button {
            Task { await choose(.typed(text), confirmed: false) }
        } label: {
            FlatRow(showsHairline: false) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Use “\(text)” as typed")
                        .font(HermesFont.callout)
                        .foregroundStyle(t.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(hint)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                if busyChoice == .typed(text) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "keyboard")
                        .foregroundStyle(t.text4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busyChoice != nil)
        .accessibilityLabel("Use \(text) as typed")
    }

    private func isBusy(_ entry: ModelRow, provider: ProviderRow) -> Bool {
        if busySlug == entry.slug { return true }
        if case .catalogue(let pair)? = busyChoice {
            return pair.model == entry.slug && pair.provider == provider.slug
        }
        return false
    }

    private func isCurrent(_ entry: ModelRow, provider: ProviderRow) -> Bool {
        if let pick {
            if pick.marksCatalogueCurrent, entry.isCurrent { return true }
            guard !pick.current.model.isEmpty, pick.current.model == entry.slug else { return false }
            return pick.current.provider.isEmpty || pick.current.provider == provider.slug
        }
        guard let model else { return entry.isCurrent }
        if model.isDraft {
            let effective = model.draftModelSlug ?? app.defaultModel
            if !effective.isEmpty { return effective == entry.slug }
        }
        if let current = model.info?.model, !current.isEmpty { return current == entry.slug }
        return entry.isCurrent
    }

    // MARK: Effort bar — pinned outside the scroll

    @ViewBuilder
    private var effortBar: some View {
        if currentModelSupportsReasoning {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack {
                    Text("Reasoning effort")
                        .hermesCaption()
                        .foregroundStyle(t.text3)
                    Spacer()
                    if !currentEffort.isEmpty {
                        Text(currentEffort)
                            .font(HermesFont.footnote)
                            .foregroundStyle(t.text3)
                    }
                }
                .padding(.horizontal, Space.s6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s3) {
                        ForEach(
                            EffortLadder.offered(canDisableReasoning: currentModelCanDisableReasoning),
                            id: \.self
                        ) { effort in
                            effortChip(effort)
                        }
                    }
                    .padding(.horizontal, Space.s6)
                }

                if !currentModelCanDisableReasoning {
                    Text(EffortLadder.mandatoryNote)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.s6)
                }
            }
            .padding(.vertical, Space.s4)
            .hairline(.top)
        }
    }

    private var currentEffort: String {
        guard let model else { return "" }
        if model.isDraft { return model.draftEffort ?? app.defaultEffort }
        return model.info?.reasoningEffort ?? ""
    }

    private var effectiveModelSlug: String {
        guard let model else { return "" }
        if model.isDraft {
            let draft = model.draftModelSlug ?? app.defaultModel
            if !draft.isEmpty { return draft }
        }
        return model.info?.model ?? ""
    }

    private var currentModelSupportsReasoning: Bool {
        let current = effectiveModelSlug
        guard let catalogue, !current.isEmpty else { return true }
        for provider in catalogue.providers where provider.models.contains(where: { $0.slug == current }) {
            return provider.supportsReasoning(current)
        }
        return true
    }

    /// FEAT-014. Read off the catalogue on every open rather than stored: the
    /// backend warms its reasoning catalogue in the background, so the honest
    /// answer for one model can change between two opens of this sheet.
    private var currentModelCanDisableReasoning: Bool {
        let current = effectiveModelSlug
        guard let catalogue, !current.isEmpty else { return true }
        for provider in catalogue.providers where provider.models.contains(where: { $0.slug == current }) {
            return provider.canDisableReasoning(current)
        }
        return true
    }

    private func effortChip(_ effort: ReasoningEffort) -> some View {
        // Compared as a value, not as a raw string: the backend spells a
        // disabled config `"none"` where this client writes `"off"`, and a
        // string compare leaves nothing ticked exactly when reasoning is off.
        let isSelected = ReasoningEffort(backendValue: currentEffort) == effort
        return Button {
            Task { await selectEffort(effort) }
        } label: {
            HStack(spacing: Space.s2) {
                if busyEffort == effort {
                    ProgressView().controlSize(.mini)
                } else {
                    EffortRung(step: effort.step)
                }
                Text(effort.rawValue)
                    .font(isSelected ? HermesFont.calloutStrong : HermesFont.callout)
                    .foregroundStyle(t.text1)
            }
            .padding(.horizontal, Space.s5)
            .frame(minHeight: Hit.min)
            .background(
                isSelected ? t.fill3 : t.fill2,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyEffort != nil)
        .accessibilityLabel("Effort \(effort.rawValue)\(isSelected ? ", selected" : "")")
    }

    // MARK: Actions

    private func load() async {
        guard let configAPI = app.configAPI else {
            #if DEBUG
            if let demo = ModelSettingsDemo.catalogueIfScreenshotting {
                apply(catalogue: demo)
                return
            }
            #endif
            loadError = "Not connected to a backend."
            return
        }
        loadError = nil
        do {
            let loaded = try await configAPI.modelOptions()
            apply(catalogue: loaded)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func apply(catalogue: ModelCatalogue) {
        self.catalogue = catalogue
        let pinned = pick?.current.provider ?? ""
        expandedProvider = catalogue.providers.first(where: { !pinned.isEmpty && $0.slug == pinned })?.id
            ?? catalogue.providers.first(where: { $0.isCurrent })?.id
            ?? catalogue.providers.first?.id
    }

    /// The setting mode's one path: hand the choice back, then show whatever came of it.
    private func choose(_ choice: ModelSettingChoice, confirmed: Bool) async {
        guard let pick else { return }
        failure = nil
        busyChoice = choice
        let outcome = await pick.onPick(choice, confirmed)
        busyChoice = nil
        switch outcome {
        case .done:
            if case .catalogue(let pair) = choice { recordRecent(pair.model) }
            dismiss()
        case .confirm(let message):
            confirm = ExpensiveConfirm(message: message) { await choose(choice, confirmed: true) }
        case .failed(let message):
            failure = message
        }
    }

    private func selectModel(_ slug: String, providerSlug: String? = nil, confirmExpensive: Bool) async {
        guard let model else { return }
        // A draft has nothing to write to: the choice paints locally and
        // `session.create` carries it, provider included, at first send.
        if model.isDraft {
            model.draftModelSlug = slug
            model.draftProviderSlug = providerSlug
            recordRecent(slug)
            dismiss()
            return
        }
        guard let configAPI = app.configAPI else {
            failure = "Not connected to a backend."
            return
        }
        // Without a session id `config.set` writes the backend's *global*
        // default model, for every client. Never do that from a chat's pill.
        guard let sessionID = model.runtimeSessionID else {
            failure = "This conversation has no session yet. Send a message first, then pick a model."
            return
        }
        failure = nil
        busySlug = slug
        defer { busySlug = nil }
        do {
            let result = try await configAPI.set(
                "model",
                value: .string(slug),
                sessionID: sessionID,
                confirmExpensiveModel: confirmExpensive
            )
            if result.confirmRequired, !confirmExpensive {
                confirm = ExpensiveConfirm(message: result.confirmMessage) {
                    await selectModel(slug, providerSlug: providerSlug, confirmExpensive: true)
                }
                return
            }
            if result.deferred { model.pendingModelWrite = true }
            recordRecent(slug)
            // session.info reconciles the pill; deferred shows the pending dot.
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func selectEffort(_ effort: ReasoningEffort) async {
        guard let model else { return }
        // Draft: local paint, carried into `session.create` — see selectModel.
        if model.isDraft {
            model.draftEffort = effort.rawValue
            return
        }
        guard let configAPI = app.configAPI else {
            failure = "Not connected to a backend."
            return
        }
        // `scope: "session"` is not self-enforcing: with no session id the
        // backend writes its global default instead, for every client.
        guard let sessionID = model.runtimeSessionID else {
            failure = "This conversation has no session yet. Send a message first, then set the effort."
            return
        }
        failure = nil
        busyEffort = effort
        defer { busyEffort = nil }
        do {
            let result = try await configAPI.set(
                "reasoning",
                value: .string(effort.rawValue),
                sessionID: sessionID,
                scope: "session"
            )
            if result.deferred { model.pendingEffortWrite = true }
            // The bar stays up: effort is a dial, not a destination — picking
            // a step and then a model is one visit, not two.
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func recordRecent(_ slug: String) {
        var recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents.removeAll { $0 == slug }
        recents.insert(slug, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(5)), forKey: Self.recentsKey)
    }
}

/// Which rungs of the reasoning ladder a given model is actually offered.
///
/// FEAT-014. The eight rungs are a client-side ladder; the backend publishes
/// only `can_disable_reasoning`, and `supported_efforts` is not forwarded
/// because it under-reports.
enum EffortLadder {
    /// `off` is dropped for a model the backend says cannot disable reasoning.
    /// Every other rung stands, and an unknown model keeps the full ladder —
    /// absence of the key means "no restriction known", never "not allowed".
    static func offered(canDisableReasoning: Bool) -> [ReasoningEffort] {
        guard !canDisableReasoning else { return ReasoningEffort.allCases }
        return ReasoningEffort.allCases.filter { $0 != .off }
    }

    /// Why the rung is missing. Shown instead of it, never on its own: a
    /// control that silently disappears is the same failure as one that
    /// silently does nothing.
    static let mandatoryNote = "This model always reasons, so there is no off. The backend raises the weakest setting to the lowest level the route supports rather than refusing it — turning reasoning off here would look applied and change nothing."
}

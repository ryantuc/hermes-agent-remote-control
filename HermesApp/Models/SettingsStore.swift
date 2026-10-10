import Foundation
import HermesServeKit
import Observation

/// The settings tree's model: the full configuration document and its schema, loaded once per connection and written back as deep-merge partials.
///
/// Writes paint first — the local document mutates in the frame of the tap, the PUT reconciles after, and a failure rolls the value back visibly.
@MainActor
@Observable
final class SettingsStore {
    private unowned let app: AppModel

    private(set) var document: JSONValue?
    private(set) var schemaFields: JSONValue = .null
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Rows whose last write failed: dotted path to message, cleared by the next attempt on that path.
    private(set) var writeFailures: [String: String] = [:]

    /// The advanced gate: local, one switch, hides the sharp rows.
    var showAdvanced: Bool {
        get { UserDefaults.standard.bool(forKey: Self.advancedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.advancedKey) }
    }

    private static let advancedKey = "hermes.settings.showAdvanced"
    private var loadedForConnection: Date?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Loading

    /// Load once per connection; a reconnect invalidates, because the backend and therefore the document may have changed.
    func loadIfNeeded() async {
        if document != nil, loadedForConnection == app.socketOpenedAt { return }
        await reload()
    }

    func reload() async {
        guard let rest = app.rest else {
            loadError = "Not connected to a backend."
            return
        }
        let generation = backendGeneration
        isLoading = true
        defer { if generation == backendGeneration { isLoading = false } }
        loadError = nil
        do {
            let profile = app.activeProfile?.hermesProfile
            let scoped = (profile?.isEmpty ?? true) ? nil : profile
            let loaded = try await rest.getConfig(profile: scoped)
            let schema = (try? await rest.getConfigSchema(profile: scoped))?["fields"] ?? .null
            // A load that set out before a backend switch answers for the backend that was left.
            guard generation == backendGeneration else { return }
            document = loaded
            schemaFields = schema
            loadedForConnection = app.socketOpenedAt
        } catch {
            guard generation == backendGeneration else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Forget everything the backend being left said, so Settings shows its unloaded state rather than one machine's configuration under another machine's name (BUG-143); called by `AppModel.teardown` when the conversations go too.
    func reset() {
        backendGeneration &+= 1
        document = nil
        schemaFields = .null
        isLoading = false
        loadError = nil
        writeFailures = [:]
        loadedForConnection = nil
        queuedChain = nil
    }

    /// Bumped by `reset()`; a load or write that crosses a reset drops its result instead of repainting the previous backend's values.
    @ObservationIgnored private var backendGeneration = 0

    // MARK: Reads

    /// Nil when the backend does not report the key, and the row then removes itself rather than showing a disabled control or an error.
    func value(_ path: String) -> JSONValue? {
        guard let document else { return nil }
        return ConfigDocument.value(at: path, in: document)
    }

    func boolValue(_ path: String) -> Bool? { value(path)?.coercedBool }
    func stringValue(_ path: String) -> String? { value(path)?.coercedString }
    func doubleValue(_ path: String) -> Double? { value(path)?.coercedDouble }

    /// Clarify-prompt wait in seconds, mirroring the backend's `resolve_clarify_timeout`: legacy `clarify.timeout` if set, else canonical `agent.clarify_timeout`, and `<= 0` is preserved as an unlimited wait.
    func clarifyTimeoutSeconds() -> Double? {
        if let legacy = doubleValue("clarify.timeout") { return legacy }
        return doubleValue("agent.clarify_timeout")
    }

    /// Approval decision wait in seconds — the backend's `approvals.timeout`, which a loaded document always answers.
    ///
    /// The error is checked first so a stale document from an earlier connection cannot win: a failed load cannot self-heal during that connection, so it uses the shipped default rather than leaving a real deadline invisible (BUG-073).
    func approvalTimeoutSeconds() -> Double? {
        if loadError != nil { return Self.defaultApprovalTimeoutSeconds }
        return doubleValue("approvals.timeout")
    }

    static let defaultApprovalTimeoutSeconds: Double = 300

    func stringListValue(_ path: String) -> [String]? {
        guard case .array(let items)? = value(path) else { return nil }
        return items.compactMap { $0.coercedString }
    }

    /// Schema-driven options for a select field, merged per request on the backend so discovery-driven sets stay live.
    func schemaOptions(_ path: String) -> [String]? {
        guard case .array(let options)? = schemaFields[path]?["options"] else { return nil }
        let values = options.compactMap { $0.coercedString }
        return values.isEmpty ? nil : values
    }

    // MARK: Writes

    /// What a write reports when there is no backend to write to, shared with the Settings root's Agent group so one thing has one explanation.
    static let disconnectedWriteMessage = SettingsTree.agentDisconnectedFooter
    /// And when there is a backend but its document never arrived: a partial PUT is a deep merge against a document, and without one there is nothing honest to send.
    static let unloadedWriteMessage = "Settings haven't loaded yet."

    /// The two keys the backend refuses to read apart (BUG-078): `PUT /api/config` applies `model_context_length` only when the same payload carries a non-empty `model`, so writing either alone loses data.
    static let modelCoupledPaths: Set<String> = ["model", "model_context_length"]

    /// The body `set` sends for one of those two keys: both of them, read out of the already-updated document.
    ///
    /// Nil when the pairing cannot help, and the context key rides only when the document has one — its absence is how the user unsets an override, and manufacturing a `0` would delete one.
    static func modelWritePartial(path: String, in document: JSONValue) -> JSONValue? {
        guard modelCoupledPaths.contains(path) else { return nil }
        guard let model = ConfigDocument.value(at: "model", in: document),
              let slug = model.coercedString, !slug.isEmpty
        else { return nil }
        var body: [String: JSONValue] = ["model": model]
        if let context = ConfigDocument.value(at: "model_context_length", in: document), !context.isNull {
            body["model_context_length"] = context
        }
        return .object(body)
    }

    /// Direct manipulation: mutate the local document in the tap's frame, PUT the minimal partial, roll back visibly on failure.
    ///
    /// BUG-096: every refusal records a `writeFailures` entry, because a refusal that leaves no trace is indistinguishable from a success and the editor sheets dismiss on silence.
    func set(_ path: String, to newValue: JSONValue) async {
        guard let rest = app.rest else {
            writeFailures[path] = Self.disconnectedWriteMessage
            return
        }
        guard let previous = document else {
            writeFailures[path] = Self.unloadedWriteMessage
            return
        }
        writeFailures[path] = nil
        let updated = ConfigDocument.setting(previous, path: path, to: newValue)
        document = updated
        let generation = backendGeneration
        do {
            let profile = app.activeProfile?.hermesProfile
            try await putConfig(
                Self.modelWritePartial(path: path, in: updated)
                    ?? ConfigDocument.partial(path: path, value: newValue),
                profile: (profile?.isEmpty ?? true) ? nil : profile,
                via: rest
            )
            // Home's draft pill reads `app.defaultModel` / `defaultEffort`, which are otherwise refreshed only on connect.
            if path == "model" || path == "agent.reasoning_effort" || path == "reasoning" {
                await app.refreshDefaultCwd()
            }
        } catch {
            // Rolling back after a backend switch would put the previous backend's document back on screen.
            guard generation == backendGeneration else { return }
            document = previous
            writeFailures[path] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: Model rows

    /// What the row for `target` shows: the slug (with its provider when one is pinned), or the inherit wording when the slot is empty.
    static func modelDisplay(_ pair: ModelPair, target: ModelSettingTarget) -> String {
        if pair.isEmpty { return target.canInherit ? inheritLabel : "None" }
        return target == .mainDefault ? pair.model : pair.displayText
    }

    static let inheritLabel = "Same as main model"

    /// What the fallback row shows for a chain of `count` models.
    static func chainDisplay(count: Int) -> String {
        switch count {
        case 0: return "None"
        case 1: return "1 model"
        default: return "\(count) models"
        }
    }

    /// The pair a model row holds, read off its model key and, when the target has one, its provider key.
    func modelPair(modelKey: String, target: ModelSettingTarget) -> ModelPair {
        ModelPair(
            providerValue: target.providerKey(forModelKey: modelKey).flatMap { value($0) },
            modelValue: value(modelKey)
        )
    }

    func fallbackChain() -> [FallbackEntry] {
        FallbackChain.entries(from: value(FallbackChain.key))
    }

    /// The whole chain, every time: the backend replaces a list rather than merging it.
    func setFallbackChain(_ entries: [FallbackEntry]) async {
        await queueFallbackChain(entries).value
    }

    /// Chain writes go one at a time, and a list queued while one is in flight replaces any list still waiting, so a slow refusal can never answer after a later success and put the older chain back. Queueing is synchronous so a gesture's place in line is fixed in the frame it happened in; the returned task finishes when the queue is empty.
    @discardableResult
    func queueFallbackChain(_ entries: [FallbackEntry]) -> Task<Void, Never> {
        queuedChain = FallbackChain.json(entries)
        if let chainWriter { return chainWriter }
        let writer = Task { await self.drainChainWrites() }
        chainWriter = writer
        return writer
    }

    @ObservationIgnored private var queuedChain: JSONValue?
    @ObservationIgnored private var chainWriter: Task<Void, Never>?

    private func drainChainWrites() async {
        while let next = queuedChain {
            queuedChain = nil
            await set(FallbackChain.key, to: next)
            // With a newer list waiting, that write decides what the backend holds; otherwise the refused write may still have landed, so the local copy from before it is not the truth.
            if writeFailures[FallbackChain.key] != nil, queuedChain == nil {
                await reloadFallbackChain()
            }
        }
        chainWriter = nil
    }

    /// Read back only the chain, leaving every other row as it is; if the read fails too, the rollback `set` made stands.
    private func reloadFallbackChain() async {
        guard let rest = app.rest else { return }
        let generation = backendGeneration
        let profile = app.activeProfile?.hermesProfile
        guard let loaded = try? await getConfig(profile: (profile?.isEmpty ?? true) ? nil : profile, via: rest),
              generation == backendGeneration,
              let current = document
        else { return }
        let chain = ConfigDocument.value(at: FallbackChain.key, in: loaded) ?? .array([])
        document = ConfigDocument.setting(current, path: FallbackChain.key, to: chain)
    }

    /// The body for a provider + model pair of sibling keys: both at once, so a provider never lands without its model or the reverse. An empty pair clears both, which is how the slot goes back to the main model.
    static func pairWritePartial(providerKey: String, modelKey: String, pair: ModelPair) -> JSONValue {
        ConfigDocument.partial(paths: [
            (path: providerKey, value: .string(pair.provider)),
            (path: modelKey, value: .string(pair.model)),
        ])
    }

    /// Write a pair of sibling keys as one partial, painting both locally first and rolling both back on failure; the failure is recorded against the model key, which is the row.
    func setModelPair(providerKey: String, modelKey: String, to pair: ModelPair) async {
        guard let rest = app.rest else {
            writeFailures[modelKey] = Self.disconnectedWriteMessage
            return
        }
        guard let previous = document else {
            writeFailures[modelKey] = Self.unloadedWriteMessage
            return
        }
        writeFailures[modelKey] = nil
        let updated = ConfigDocument.setting(
            ConfigDocument.setting(previous, path: providerKey, to: .string(pair.provider)),
            path: modelKey, to: .string(pair.model)
        )
        document = updated
        let generation = backendGeneration
        do {
            let profile = app.activeProfile?.hermesProfile
            try await rest.putConfig(
                Self.pairWritePartial(providerKey: providerKey, modelKey: modelKey, pair: pair),
                profile: (profile?.isEmpty ?? true) ? nil : profile
            )
        } catch {
            guard generation == backendGeneration else { return }
            document = previous
            writeFailures[modelKey] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    enum AssignmentOutcome: Equatable {
        case applied
        /// The backend wants a yes before an expensive model; call again with `confirmExpensive`.
        case confirm(String)
        case failed(String)
    }

    /// Assign a catalogue pick through `POST /api/model/set`, the route Desktop's picker uses, then re-read the document so the slug the backend normalised and anything it touched beside it are what the rows show.
    func assignModel(
        _ pair: ModelPair,
        slot: ModelAssignmentAPI.Slot,
        rowKey: String,
        confirmExpensive: Bool = false
    ) async -> AssignmentOutcome {
        guard let auth = app.auth else {
            writeFailures[rowKey] = Self.disconnectedWriteMessage
            return .failed(Self.disconnectedWriteMessage)
        }
        writeFailures[rowKey] = nil
        let generation = backendGeneration
        do {
            let profile = app.activeProfile?.hermesProfile
            let result = try await ModelAssignmentAPI(auth: auth).assign(
                pair, to: slot, confirmExpensive: confirmExpensive,
                profile: (profile?.isEmpty ?? true) ? nil : profile
            )
            guard generation == backendGeneration else { return .failed(Self.backendChangedMessage) }
            if result.confirmRequired, !confirmExpensive {
                return .confirm(result.confirmMessage)
            }
            guard result.ok else {
                let message = "The backend did not apply the model."
                writeFailures[rowKey] = message
                return .failed(message)
            }
            await reload()
            if case .main = slot { await app.refreshDefaultCwd() }
            return .applied
        } catch {
            guard generation == backendGeneration else { return .failed(Self.backendChangedMessage) }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            writeFailures[rowKey] = message
            return .failed(message)
        }
    }

    static let backendChangedMessage = "The backend changed while saving. Check the setting on the new one."

    private func putConfig(_ partial: JSONValue, profile: String?, via rest: RestAPI) async throws {
        if let backend = configBackendForTesting {
            _ = try await backend("PUT", partial)
            return
        }
        try await rest.putConfig(partial, profile: profile)
    }

    private func getConfig(profile: String?, via rest: RestAPI) async throws -> JSONValue {
        if let backend = configBackendForTesting {
            return try await backend("GET", nil)
        }
        return try await rest.getConfig(profile: profile)
    }

    // MARK: Test seam

    /// Stands in for `GET` and `PUT /api/config` when set, so a test can decide when each request answers and whether it fails; nil everywhere but tests.
    @ObservationIgnored var configBackendForTesting: ((_ method: String, _ body: JSONValue?) async throws -> JSONValue)?

    #if DEBUG
    /// Replace the loaded document directly, so the approval countdown can be tested against a non-default `approvals.timeout`.
    ///
    /// Callers must inject a nested document (`{"approvals": {"timeout": 42}}`): the path is split on `.` and walked, so a flat key reads back nil.
    func injectDocumentForTesting(_ document: JSONValue) {
        self.document = document
        loadError = nil
    }

    /// Model the interval after a configuration request starts and before it resolves, which the harness cannot otherwise reach because its REST endpoint is deliberately dead.
    func markConfigLoadInFlightForTesting() {
        reset()
    }

    /// Stand a document in for a backend's, as loaded for the current connection, so the screenshot harness can photograph the settings rows with no backend at all.
    func seedDocumentForScreenshots(_ document: JSONValue) {
        self.document = document
        loadError = nil
        loadedForConnection = app.socketOpenedAt
    }
    #endif
}

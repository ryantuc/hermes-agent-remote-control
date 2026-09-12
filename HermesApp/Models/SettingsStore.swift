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
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        do {
            let profile = app.activeProfile?.hermesProfile
            let scoped = (profile?.isEmpty ?? true) ? nil : profile
            document = try await rest.getConfig(profile: scoped)
            schemaFields = (try? await rest.getConfigSchema(profile: scoped))?["fields"] ?? .null
            loadedForConnection = app.socketOpenedAt
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

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
        do {
            let profile = app.activeProfile?.hermesProfile
            try await rest.putConfig(
                Self.modelWritePartial(path: path, in: updated)
                    ?? ConfigDocument.partial(path: path, value: newValue),
                profile: (profile?.isEmpty ?? true) ? nil : profile
            )
            // Home's draft pill reads `app.defaultModel` / `defaultEffort`, which are otherwise refreshed only on connect.
            if path == "model" || path == "agent.reasoning_effort" || path == "reasoning" {
                await app.refreshDefaultCwd()
            }
        } catch {
            document = previous
            writeFailures[path] = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: Test seam

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
        document = nil
        loadError = nil
    }
    #endif
}

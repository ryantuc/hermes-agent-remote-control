import Foundation
import HermesServeKit

/// The delegated-agent roster's reads and per-agent controls for one chat: hydrate from `subagent.list`, read one agent's live tail, steer it, stop it.
///
/// Live frames stay the authority; a read only fills in what they could not deliver (a chat reopened mid-fan-out, a relaunch, a `subagent.complete` lost while the phone was away). A backend without these methods answers -32601, and every feature here then hides rather than errors.
@MainActor
final class SubagentRosterModel {
    /// The socket whose backend lacks `subagent.list`; nothing is asked again until the connection changes.
    private var listUnsupportedOn: Date?
    private var tailUnsupportedOn: Date?
    private var steerUnsupportedOn: Date?
    private var listing: Set<String> = []

    /// Ask for the roster once, in the background: after a chat opens or reattaches.
    func hydrate(app: AppModel, sessionID: String) {
        Task { await self.refresh(app: app, sessionID: sessionID) }
    }

    /// One `subagent.list` read merged into the session's roster; false when this backend does not answer it, which ends a poll.
    @discardableResult
    func refresh(app: AppModel, sessionID: String) async -> Bool {
        guard let client = Self.client(app), !sessionID.isEmpty else { return false }
        let socket = app.socketOpenedAt
        guard listUnsupportedOn != socket else { return false }
        guard listing.insert(sessionID).inserted else { return true }
        defer { listing.remove(sessionID) }
        let observedAt = Date()
        do {
            guard let roster = try await SubagentsAPI(client: client).list(sessionID: sessionID) else { return true }
            guard app.socketOpenedAt == socket else { return true }
            if app.engine.reconcileSubagents(sessionID: sessionID, roster: roster, observedAt: observedAt) {
                app.publish(sessionID: sessionID)
            }
            return true
        } catch {
            if SubagentsAPI.isUnsupported(error) {
                listUnsupportedOn = socket
                return false
            }
            return true
        }
    }

    // MARK: One agent

    enum TailOutcome: Equatable {
        case text(String, truncated: Bool)
        /// The backend has nothing to show for this agent: it has not written anything yet, it ended, or this connection does not own it.
        case unavailable
        /// This backend cannot read a tail at all; the sheet shows the progress lines it already has.
        case unsupported
    }

    func tail(app: AppModel, row: SubagentRow) async -> TailOutcome {
        guard !row.sessionID.isEmpty, !row.wireSubagentID.isEmpty else { return .unsupported }
        guard let client = Self.client(app) else { return .unavailable }
        let socket = app.socketOpenedAt
        guard tailUnsupportedOn != socket else { return .unsupported }
        do {
            let tail = try await SubagentsAPI(client: client).tail(sessionID: row.sessionID, subagentID: row.wireSubagentID)
            guard tail.available, !tail.text.isEmpty else { return .unavailable }
            return .text(tail.text, truncated: tail.truncated)
        } catch {
            if SubagentsAPI.isUnsupported(error) {
                tailUnsupportedOn = socket
                return .unsupported
            }
            return .unavailable
        }
    }

    func canSteer(app: AppModel, row: SubagentRow) -> Bool {
        Self.client(app) != nil && !row.isTerminal && !row.wireSubagentID.isEmpty && !row.sessionID.isEmpty
            && steerUnsupportedOn != app.socketOpenedAt
    }

    enum ControlOutcome: Equatable {
        case done(String)
        case refused(String)
    }

    func steer(app: AppModel, row: SubagentRow, text: String) async -> ControlOutcome {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .refused("Type a message for the agent first.") }
        guard let client = Self.client(app), canSteer(app: app, row: row) else {
            return .refused("Not connected, so the message was not sent.")
        }
        let socket = app.socketOpenedAt
        do {
            let receipt = try await SubagentsAPI(client: client).steer(sessionID: row.sessionID, subagentID: row.wireSubagentID, text: message)
            return receipt.isQueued
                ? .done("Sent. The agent reads it before its next step.")
                : .refused("The agent didn't take the message. It may be finishing, or it was started from another window.")
        } catch {
            if SubagentsAPI.isUnsupported(error) {
                steerUnsupportedOn = socket
                return .refused("This backend can't send messages to an agent.")
            }
            return .refused("The message was not sent: \(error.localizedDescription)")
        }
    }

    /// Stop one agent through the same `subagent.interrupt` the chat's Stop uses.
    ///
    /// `found: false` means either that it already ended or that this connection may not stop it (control needs the exact session generation that spawned it, `tui_gateway/methods_subagents.py:29-37`), so the roster, which follows the conversation's lineage, is asked which: a listed agent is still running and is not claimed as finished.
    func stop(app: AppModel, row: SubagentRow) async -> ControlOutcome {
        guard let client = Self.client(app), let api = app.sessionAPI, !row.isTerminal, !row.wireSubagentID.isEmpty, !row.sessionID.isEmpty else {
            return .refused("Not connected, so the agent was not stopped.")
        }
        do {
            let result = try await api.interruptSubagent(subagentID: row.wireSubagentID, sessionID: row.sessionID)
            if result.found { return .done("Asked the agent to stop.") }
        } catch {
            return .refused("The agent was not stopped: \(error.localizedDescription)")
        }
        let observedAt = Date()
        guard let roster = try? await SubagentsAPI(client: client).list(sessionID: row.sessionID) else {
            // No roster on this backend: the chat Stop's own rule, where a started agent the backend has never heard of ended.
            if app.engine.markSubagentInterrupted(sessionID: row.sessionID, wireSubagentID: row.wireSubagentID) {
                app.publish(sessionID: row.sessionID)
                return .done("It had already finished.")
            }
            return .refused("It hasn't started yet, so there is nothing to stop until it does.")
        }
        if app.engine.reconcileSubagents(sessionID: row.sessionID, roster: roster, observedAt: observedAt) {
            app.publish(sessionID: row.sessionID)
        }
        if let listed = roster.subagents.first(where: { $0.subagentID == row.wireSubagentID }) {
            return .refused(listed.hasStarted
                ? "Hermes still lists this agent as working but would not stop it from this phone. Stop it from the window that started it."
                : "It hasn't started yet, so there is nothing to stop until it does.")
        }
        return .done("It had already finished.")
    }

    /// The demo's conversation is not on any backend, so nothing here asks one.
    private static func client(_ app: AppModel) -> HermesClient? {
        guard app.connectionState.isOpen, !app.isDemoActive else { return nil }
        return app.client
    }
}

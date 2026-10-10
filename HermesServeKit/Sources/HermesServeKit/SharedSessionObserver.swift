import Foundation

public enum TurnOwnership: String, Sendable, Equatable { case local, other, unknown }

/// Optional display/correlation evidence. It never grants authority or retries work.
final class SharedSessionObserver {
    var socketID = ""
    private var references: [String: [String: String]] = [:]
    private var referenceOrder: [(String, String)] = []
    private var bindings: [String: [String: String]] = [:]

    func resetEpoch() { bindings.removeAll() }

    func checkpointReferences(_ sid: String) -> [String: String] { references[sid] ?? [:] }
    func checkpointBindings(_ sid: String) -> [String: String] { bindings[sid] ?? [:] }
    func restoreCheckpoint(_ checkpoint: TurnCheckpoint) {
        forget(checkpoint.sessionID)
        for (ref, entry) in checkpoint.references {
            register(sessionID: checkpoint.sessionID, ref: ref, entryID: entry)
        }
        bindings[checkpoint.sessionID] = checkpoint.bindings
    }

    func acknowledge(sessionID: String, ack: PromptAck) {
        guard let id = ack.raw["submission"]?["input_id"]?.coercedString,
              let ref = ack.raw["submission"]?["ref"]?.coercedString,
              let entry = references[sessionID]?[ref] else { return }
        if !((bindings[sessionID] ?? [:]).contains { $0.value == entry && $0.key != id }) {
            bindings[sessionID, default: [:]][id] = entry
        }
    }

    func register(sessionID: String, ref: String, entryID: String) {
        if references[sessionID]?[ref] == nil { referenceOrder.append((sessionID, ref)) }
        references[sessionID, default: [:]][ref] = entryID
        while referenceOrder.count > 256 {
            let (sid, old) = referenceOrder.removeFirst()
            references[sid]?[old] = nil
        }
    }

    func forget(_ sid: String) {
        references[sid] = nil; bindings[sid] = nil
        referenceOrder.removeAll { $0.0 == sid }
    }

    func consume(_ event: GatewayEvent, state: inout SessionTurnState) -> Bool {
        let turn = event.params["turn"]
        let execution = turn?["id"]?.coercedString ?? ""
        if !execution.isEmpty {
            if event.type == "message.start" {
                if state.observedExecutions.contains(execution) { return false }
                state.observedExecutions.append(execution)
                state.observedExecutions = Array(state.observedExecutions.suffix(256))
                state.executionID = execution
                state.observedInputIDs = []
            } else if let current = state.executionID, execution != current {
                return false
            } else if state.executionID == nil {
                state.executionID = execution
            }
            let source = turn?["source"]
            let currentSocket = source?["kind"]?.coercedString == "connection"
                && !socketID.isEmpty && source?["socket_id"]?.coercedString == socketID
            let inputs = event.payload["inputs"]?.arrayValue ?? []
            let completeLocal = event.type == "message.start" && !inputs.isEmpty
                && event.payload["inputs_complete"]?.coercedBool == true
                && inputs.allSatisfy { references[event.sessionID]?[$0["ref"]?.coercedString ?? ""] != nil }
            if event.type == "message.start" || state.turnOwnership == .unknown {
                state.turnOwnership = currentSocket || completeLocal ? .local : .unknown
                state.turnStartedLocally = state.turnOwnership == .local
            }
        }
        if event.type == "message.start" || event.type == "message.input" {
            let ids = (event.payload["inputs"]?.arrayValue ?? []).compactMap { $0["id"]?.coercedString }
            if event.type == "message.input", !ids.isEmpty, ids.allSatisfy({ state.observedInputIDs.contains($0) }) { return false }
            projectInput(event.payload, sid: event.sessionID, correction: event.type == "message.input", state: &state)
        }
        if let snapshot = event.payload["submission_state"] {
            applySubmissionState(snapshot, sid: event.sessionID, state: &state)
        }
        return true
    }

    private func projectInput(_ payload: JSONValue, sid: String, correction: Bool, state: inout SessionTurnState) {
        let inputs = Array((payload["inputs"]?.arrayValue ?? []).prefix(256))
        let ids = inputs.compactMap { $0["id"]?.coercedString }.filter { !$0.isEmpty }
        guard !ids.isEmpty, !ids.allSatisfy({ state.observedInputIDs.contains($0) }) else { return }
        state.observedInputIDs.formUnion(ids)
        if state.observedInputIDs.count > 512 { state.observedInputIDs = Set(ids) }
        for input in inputs {
            if let ref = input["ref"]?.coercedString, references[sid]?[ref] != nil {
                state.submissionDispositions[ref] = "executing"
            }
        }
        // Null is deliberate (hidden/system input). Missing is the legacy path.
        guard let input = payload["input"], !input.isNull,
              input["role"]?.coercedString == "user" else { return }
        let display = UserInputDisplay.project(input["text"]?.text ?? "")
        let text = display.body
        guard !text.isEmpty || !display.refs.isEmpty else { return }
        var targets: [String] = []
        for input in inputs {
            guard let id = input["id"]?.coercedString,
                  let ref = input["ref"]?.coercedString,
                  let entry = references[sid]?[ref] else { continue }
            // A repeated ref with a different input id is a second occurrence.
            let claimedBy = bindings[sid]?.first { $0.value == entry }?.key
            if claimedBy == nil || claimedBy == id {
                bindings[sid, default: [:]][id] = entry
                if state.entries.contains(where: { $0.id == entry }), !targets.contains(entry) { targets.append(entry) }
            }
        }
        let entryID = targets.first ?? "observed-input-\(ids[0])"
        // A merged queue envelope has one canonical display input. Every local
        // occurrence is named by the server, so these optimistic rows can merge.
        state.entries.removeAll { $0.id != entryID && targets.contains($0.id) }
        if let index = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[index].text = text
            if !display.refs.isEmpty { state.entries[index].imageRefs = display.refs }
            state.entries[index].noticeKind = correction ? "correction" : ""
        } else {
            state.entries.append(ChatEntry(id: entryID, kind: .user, text: text, imageRefs: display.refs,
                                           noticeKind: correction ? "correction" : ""))
        }
        for id in ids { bindings[sid, default: [:]][id] = entryID }
        if (bindings[sid]?.count ?? 0) > 512 { bindings[sid] = Dictionary(ids.map { ($0, entryID) }, uniquingKeysWith: { first, _ in first }) }
    }

    func applySubmissionState(_ snapshot: JSONValue, sid: String, state: inout SessionTurnState) {
        guard let revision = snapshot["revision"]?.coercedInt, revision > state.submissionRevision else { return }
        state.submissionRevision = revision
        state.queuedInputIDs = Set((snapshot["queued"]?.arrayValue ?? []).prefix(256).flatMap {
            ($0["inputs"]?.arrayValue ?? []).compactMap { $0["id"]?.coercedString }
        })
        state.queuedInputsComplete = snapshot["queued_complete"]?.coercedBool ?? false
        for envelope in (snapshot["queued"]?.arrayValue ?? []).prefix(256) {
            for input in (envelope["inputs"]?.arrayValue ?? []).prefix(256) {
                if let ref = input["ref"]?.coercedString, references[sid]?[ref] != nil {
                    state.submissionDispositions[ref] = "queued"
                }
            }
        }
        // Absence/eviction proves nothing. Only a positive named outcome changes an entry.
        for outcome in (snapshot["outcomes"]?.arrayValue ?? []).prefix(256) {
            guard let id = outcome["input"]?["id"]?.coercedString,
                  let disposition = outcome["disposition"]?.coercedString else { continue }
            state.inputOutcomes[id] = disposition
            if let ref = outcome["input"]?["ref"]?.coercedString, references[sid]?[ref] != nil {
                state.submissionDispositions[ref] = disposition
            }
            guard let entryID = bindings[sid]?[id], let index = state.entries.firstIndex(where: { $0.id == entryID }) else { continue }
            switch disposition {
            case "cancelled": state.entries[index].noticeKind = "cancelled"
            case "unresolved": state.entries[index].noticeKind = "unconfirmed"
            case "failed_before_start":
                state.entries[index].status = "error"
                state.entries[index].errorText = "The backend could not start this message."
            case "terminal", "absorbed":
                if state.entries[index].noticeKind == "queued" { state.entries[index].noticeKind = "" }
            default: break
            }
        }
        if state.inputOutcomes.count > 512 { state.inputOutcomes = [:] }
        if state.submissionDispositions.count > 512 { state.submissionDispositions = [:] }
    }

    func restore(_ result: SessionResumeResult, state: inout SessionTurnState) {
        if let raw = result.inflight?.raw, let id = raw["turn"]?["id"]?.coercedString, !id.isEmpty {
            state.executionID = id
            state.observedExecutions.append(id)
            let source = raw["turn"]?["source"]
            let inputs = raw["inputs"]?.arrayValue ?? []
            let local = !inputs.isEmpty && raw["inputs_complete"]?.coercedBool == true
                && inputs.allSatisfy { references[result.sessionID]?[$0["ref"]?.coercedString ?? ""] != nil }
            state.turnOwnership = (source?["kind"]?.coercedString == "connection" && !socketID.isEmpty
                && source?["socket_id"]?.coercedString == socketID) || local ? .local : .unknown
            state.turnStartedLocally = state.turnOwnership == .local
            state.observedInputIDs.formUnion(inputs.compactMap { $0["id"]?.coercedString })
            for input in inputs {
                if let ref = input["ref"]?.coercedString, references[result.sessionID]?[ref] != nil {
                    state.submissionDispositions[ref] = "executing"
                }
            }
            for observation in (raw["input_observations"]?.arrayValue ?? []).prefix(256) {
                state.observedInputIDs.formUnion((observation["inputs"]?.arrayValue ?? []).compactMap { $0["id"]?.coercedString })
            }
        }
        if let snapshot = result.raw["submission_state"] { applySubmissionState(snapshot, sid: result.sessionID, state: &state) }
    }
}

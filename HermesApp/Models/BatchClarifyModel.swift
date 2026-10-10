import Foundation
import HermesServeKit
import Observation

/// The state machine behind a batch clarify card — the form of `clarify.request` that carries a `questions` array instead of one question.
///
/// Three rules decide the design: nothing is sent until Confirm, because the backend treats "every qid locked" as completion; every answer carries its `question_id`, because a `clarify.respond` without one is the cancel-all path (BUG-041); and a deadline does not erase what already landed.
@MainActor
@Observable
final class BatchClarifyModel {

    /// One question's answer as the user has built it so far — not yet sent.
    struct Stage: Equatable {
        var choices: [String] = []
        var draft: String = ""
    }

    /// How the card ended, nil while it is still answerable.
    enum Outcome: Equatable {
        /// Every answer reached the backend; the final lock resumed the turn.
        case confirmed
        /// Cancel-all: one `clarify.respond` with no `question_id`.
        case cancelled
        /// The deadline passed; `retained` is what the backend is still holding, which is not necessarily nothing.
        case expired(retained: [String: String])
    }

    let requestID: String
    let questions: [ClarifyQuestion]
    private let sessionID: String
    private let serverRequest: ServerRequestIdentity?
    private var editedQuestionIDs: Set<String> = []
    private var snapshotAnswers: [String: String]
    private var sourceRevision: Int?
    /// Newest authority for each answer, including acknowledgments whose projection has not rendered yet.
    private var answerRevisions: [String: Int] = [:]

    private(set) var staged: [String: Stage] = [:]
    /// Answers the backend holds, keyed by qid: seeded from a reconnect replay and extended as each lock is accepted.
    private(set) var lockedAnswers: [String: String]
    private(set) var isSubmitting = false
    private(set) var outcome: Outcome?
    /// Set when a lock was refused mid-batch; the card stays answerable, because the backend is still blocked on the questions that did not land.
    private(set) var failure: String?

    init(request: ClarifyRequestEvent) {
        requestID = request.id
        sessionID = request.sessionID
        serverRequest = request.serverRequest
        questions = request.questions
        lockedAnswers = request.lockedAnswers
        snapshotAnswers = request.lockedAnswers
        sourceRevision = request.sourceRevision
        if let revision = request.sourceRevision {
            answerRevisions = request.lockedAnswers.mapValues { _ in revision }
        }
        for question in request.questions {
            guard let locked = request.lockedAnswers[question.id] else { continue }
            staged[question.id] = Self.restoredStage(locked, for: question)
        }
    }

    /// A mounted card keeps its model across same-ID snapshots. Adopt peer locks without replacing unsent local edits, including an intentionally cleared answer.
    func reconcile(_ request: ClarifyRequestEvent) {
        guard outcome == nil, request.id == requestID, request.sessionID == sessionID,
              request.serverRequest == serverRequest, request.questions == questions else { return }
        if let revision = request.sourceRevision {
            guard revision > (sourceRevision ?? -1) else { return }
            sourceRevision = revision
        } else if sourceRevision != nil {
            return // A revision-less projection cannot supersede current-request authority.
        }
        for question in questions {
            guard let locked = request.lockedAnswers[question.id] else { continue }
            if let revision = request.sourceRevision {
                guard revision >= (answerRevisions[question.id] ?? -1) else { continue }
                answerRevisions[question.id] = revision
            } else {
                // Legacy events have no freshness signal. Preserve the existing repeated-value fallback, including incomplete snapshots.
                guard snapshotAnswers[question.id] != locked else { continue }
            }
            snapshotAnswers[question.id] = locked
            lockedAnswers[question.id] = locked
            if !editedQuestionIDs.contains(question.id) {
                staged[question.id] = Self.restoredStage(locked, for: question)
            }
        }
    }

    // MARK: - Reading

    func stage(for question: ClarifyQuestion) -> Stage { staged[question.id] ?? Stage() }

    /// What this question would send right now, or nil while it is unanswered; a multi-select answer goes as a JSON array, because the backend falls back to splitting on commas and would tear a choice containing one in half.
    func answer(for question: ClarifyQuestion) -> String? {
        let current = stage(for: question)
        if !current.choices.isEmpty {
            return question.multiSelect
                ? Self.encodeMultiSelect(current.choices)
                : current.choices[0]
        }
        let typed = current.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    func isSelected(_ choice: String, for question: ClarifyQuestion) -> Bool {
        stage(for: question).choices.contains(choice)
    }

    func isAnswered(_ question: ClarifyQuestion) -> Bool { answer(for: question) != nil }

    var answeredCount: Int { questions.filter { answer(for: $0) != nil }.count }

    /// Confirm is gated on a complete set: a partial Confirm would leave the agent blocked on the rest until the clarify deadline.
    var canConfirm: Bool { !questions.isEmpty && answeredCount == questions.count }

    var isSettled: Bool { outcome != nil }

    // MARK: - Editing

    func toggleChoice(_ choice: String, for question: ClarifyQuestion) {
        guard outcome == nil, !isSubmitting else { return }
        var current = stage(for: question)
        if question.multiSelect {
            if let index = current.choices.firstIndex(of: choice) {
                current.choices.remove(at: index)
            } else {
                current.choices.append(choice)
            }
        } else {
            current.choices = current.choices == [choice] ? [] : [choice]
        }
        current.draft = ""
        staged[question.id] = current
        editedQuestionIDs.insert(question.id)
        failure = nil
    }

    func setDraft(_ text: String, for question: ClarifyQuestion) {
        guard outcome == nil, !isSubmitting else { return }
        staged[question.id] = Stage(choices: [], draft: text)
        editedQuestionIDs.insert(question.id)
        failure = nil
    }

    // MARK: - Resolving

    /// Confirm-and-continue: one `clarify.respond` per question, in order and one at a time, because the last lock resolves the blocked tool and a reordered burst could complete the batch with an answer still missing.
    ///
    /// A refusal stops the loop and leaves the card live, with the answers that did land still locked.
    @discardableResult
    func confirm(send: (_ questionID: String, _ answer: String) async -> ClarifyRespondResult?) async -> Bool {
        guard outcome == nil, !isSubmitting, canConfirm else { return false }
        isSubmitting = true
        failure = nil
        defer { isSubmitting = false }

        // Update edited locks before the final missing answer, which immediately resolves the batch. Recompute after each await so a peer lock learned during submission gets the same ordering protection.
        while true {
            guard outcome == nil, canConfirm else { return false }
            let changed = questions.filter { lockedAnswers[$0.id] != answer(for: $0) }
            guard let question = changed.first(where: { lockedAnswers[$0.id] != nil }) ?? changed.first else { break }
            let value = answer(for: question) ?? ""
            guard let receipt = await send(question.id, value), receipt.status != "expired" else {
                failure = "Some answers did not reach the backend. The questions still shown are the ones it is waiting for."
                return false
            }
            editedQuestionIDs.remove(question.id)
            if let revision = receipt.sourceRevision {
                if revision < (answerRevisions[question.id] ?? -1) {
                    // A later peer projection can arrive before this await returns. The sent draft is no longer unsent, so show that newer answer.
                    if let locked = lockedAnswers[question.id] {
                        staged[question.id] = Self.restoredStage(locked, for: question)
                    }
                    continue
                }
                answerRevisions[question.id] = revision
            }
            lockedAnswers[question.id] = value
        }
        outcome = .confirmed
        return true
    }

    /// Cancel-all: the caller sends the one `clarify.respond` with no `question_id`, and this only records that the card is done.
    func cancel() {
        guard outcome == nil else { return }
        outcome = .cancelled
    }

    /// `clarify.expire` arrived; whatever the backend already holds survives as absences rather than skips, so the card settles on what was retained.
    func expire() {
        guard outcome == nil else { return }
        outcome = .expired(retained: lockedAnswers)
    }

    // MARK: - Helpers

    private static func restoredStage(_ answer: String, for question: ClarifyQuestion) -> Stage {
        if question.multiSelect, let data = answer.data(using: .utf8),
           let choices = try? JSONDecoder().decode([String].self, from: data),
           !choices.isEmpty, choices.allSatisfy({ question.choices.contains($0) }) {
            return Stage(choices: choices)
        }
        if question.choices.contains(answer) { return Stage(choices: [answer]) }
        return Stage(draft: answer)
    }

    static func encodeMultiSelect(_ choices: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: choices),
              let text = String(data: data, encoding: .utf8)
        else { return choices.joined(separator: ", ") }
        return text
    }
}

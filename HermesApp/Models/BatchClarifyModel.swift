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

    private(set) var staged: [String: Stage] = [:]
    /// Answers the backend holds, keyed by qid: seeded from a reconnect replay and extended as each lock is accepted.
    private(set) var lockedAnswers: [String: String]
    private(set) var isSubmitting = false
    private(set) var outcome: Outcome?
    /// Set when a lock was refused mid-batch; the card stays answerable, because the backend is still blocked on the questions that did not land.
    private(set) var failure: String?

    init(request: ClarifyRequestEvent) {
        requestID = request.id
        questions = request.questions
        lockedAnswers = request.lockedAnswers
        // Restore a reconnect replay onto the controls that produced it: an answer matching an offered choice comes back selected, anything else as free text.
        for question in request.questions {
            guard let locked = request.lockedAnswers[question.id], !locked.isEmpty else { continue }
            if let choice = question.choices.first(where: { $0 == locked }) {
                staged[question.id] = Stage(choices: [choice], draft: "")
            } else {
                staged[question.id] = Stage(choices: [], draft: locked)
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
        failure = nil
    }

    func setDraft(_ text: String, for question: ClarifyQuestion) {
        guard outcome == nil, !isSubmitting else { return }
        staged[question.id] = Stage(choices: [], draft: text)
        failure = nil
    }

    // MARK: - Resolving

    /// Confirm-and-continue: one `clarify.respond` per question, in order and one at a time, because the last lock resolves the blocked tool and a reordered burst could complete the batch with an answer still missing.
    ///
    /// A refusal stops the loop and leaves the card live, with the answers that did land still locked.
    @discardableResult
    func confirm(send: (_ questionID: String, _ answer: String) async -> Bool) async -> Bool {
        guard outcome == nil, !isSubmitting, canConfirm else { return false }
        isSubmitting = true
        failure = nil
        defer { isSubmitting = false }

        for question in questions {
            let value = answer(for: question) ?? ""
            guard await send(question.id, value) else {
                failure = "Some answers did not reach the backend. The questions still shown are the ones it is waiting for."
                return false
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

    static func encodeMultiSelect(_ choices: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: choices),
              let text = String(data: data, encoding: .utf8)
        else { return choices.joined(separator: ", ") }
        return text
    }
}

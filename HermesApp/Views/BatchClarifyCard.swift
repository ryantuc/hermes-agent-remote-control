import HermesServeKit
import SwiftUI

/// A `clarify.request` that carries several questions at once.
///
/// The backend calls the batch complete only when the last qid lands, so this card stages every answer locally and sends the whole set on Confirm; Skip is one `clarify.respond` with no `question_id`, the only path that may omit the id.
@MainActor
struct BatchClarifyCard: View {
    @Environment(\.hermes) private var t

    /// Locks one answer and returns its acknowledgment, or nil on failure.
    let send: (_ questionID: String, _ answer: String) async -> ClarifyRespondResult?
    /// Every answer landed and the turn has resumed — tear the card down.
    let onConfirmed: () -> Void
    /// Cancel-all. The caller sends the bare `clarify.respond`.
    let onCancelAll: () -> Void
    /// When the backend's clarify wait runs out, if it has one at all: the answers already locked survive and the rest are reported to the agent as absences.
    let deadline: Date?

    private let request: ClarifyRequestEvent
    @State private var model: BatchClarifyModel

    init(
        request: ClarifyRequestEvent,
        deadline: Date?,
        send: @escaping (_ questionID: String, _ answer: String) async -> ClarifyRespondResult?,
        onConfirmed: @escaping () -> Void,
        onCancelAll: @escaping () -> Void,
        initialModel: BatchClarifyModel? = nil
    ) {
        self.request = request
        _model = State(initialValue: initialModel ?? BatchClarifyModel(request: request))
        self.deadline = deadline
        self.send = send
        self.onConfirmed = onConfirmed
        self.onCancelAll = onCancelAll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s7) {
            if case .expired(let retained)? = model.outcome {
                expiredNotice(retained: retained)
            } else {
                progressLine
                ForEach(model.questions) { question in
                    questionBlock(question)
                }
                if let failure = model.failure {
                    Text(failure)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.danger)
                }
                controls
            }
        }
        .disabled(model.isSubmitting)
        .onChange(of: request, initial: true) { _, latest in model.reconcile(latest) }
        .task(id: deadline) { await settleAtDeadline() }
    }

    // MARK: - Pieces

    private var progressLine: some View {
        Text("\(model.answeredCount) of \(model.questions.count) answered")
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
    }

    @ViewBuilder
    private func questionBlock(_ question: ClarifyQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: model.isAnswered(question) ? "checkmark.circle.fill" : "circle")
                    .font(HermesFont.footnote)
                    .foregroundStyle(model.isAnswered(question) ? t.action : t.text3)
                Text(question.question)
                    .font(HermesFont.body)
                    .foregroundStyle(t.text1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Keyed by offset: `choices` is `[String]` and the backend does not guarantee uniqueness, so `id: \.self` collides.
            ForEach(Array(question.choices.enumerated()), id: \.offset) { _, choice in
                Button {
                    model.toggleChoice(choice, for: question)
                } label: {
                    HStack(spacing: Space.s3) {
                        Image(systemName: selectionSymbol(question, choice))
                            .foregroundStyle(model.isSelected(choice, for: question) ? t.action : t.text3)
                        Text(choice).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            TextField(
                question.choices.isEmpty ? "Your answer" : "Or type your own answer",
                text: draft(for: question),
                axis: .vertical
            )
            .font(HermesFont.body)
            .lineLimit(1...4)
            .padding(Space.s5)
            .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    private var controls: some View {
        HStack(spacing: Space.s4) {
            Button("Skip all") {
                model.cancel()
                onCancelAll()
            }
            .buttonStyle(SecondaryButtonStyle())

            Button("Send answers") { Task { await confirm() } }
                .buttonStyle(PrimaryButtonStyle())
                // A partial Confirm would lock some answers and leave the agent blocked on the rest until the clarify deadline.
                .disabled(!model.canConfirm)
        }
    }

    private func expiredNotice(retained: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("The question timed out.")
                .font(HermesFont.body)
                .foregroundStyle(t.text1)
            Text(
                retained.isEmpty
                    ? "Nothing was sent, and Hermes has been told the questions went unanswered."
                    : "\(retained.count) of \(model.questions.count) answers had already reached Hermes and were kept; the rest are marked unanswered."
            )
            .font(HermesFont.footnote)
            .foregroundStyle(t.text3)
        }
    }

    // MARK: - Behaviour

    private func confirm() async {
        let landed = await model.confirm(send: send)
        if landed { onConfirmed() }
    }

    private func settleAtDeadline() async {
        guard let deadline else { return }
        let seconds = deadline.timeIntervalSinceNow
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
        }
        model.expire()
    }

    private func draft(for question: ClarifyQuestion) -> Binding<String> {
        Binding(
            get: { model.stage(for: question).draft },
            set: { model.setDraft($0, for: question) }
        )
    }

    private func selectionSymbol(_ question: ClarifyQuestion, _ choice: String) -> String {
        let picked = model.isSelected(choice, for: question)
        if question.multiSelect { return picked ? "checkmark.square.fill" : "square" }
        return picked ? "largecircle.fill.circle" : "circle"
    }
}

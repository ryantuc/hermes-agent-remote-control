import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile
@testable import HermesServeKit

@MainActor
final class BatchClarifyReconciliationTests: XCTestCase {
    func testPeerSnapshotAdoptsUntouchedAnswersAndPreservesEditedAndClearedDrafts() {
        let questions = questions(["edited", "cleared", "untouched"])
        let model = BatchClarifyModel(request: request(questions, answers: ["edited": "before", "cleared": "before"]))
        model.setDraft("local edit", for: questions[0])
        model.setDraft("", for: questions[1])

        let peerAnswers = ["edited": "peer edit", "cleared": "peer cleared", "untouched": "peer answer"]
        model.reconcile(request(questions, answers: peerAnswers))

        XCTAssertEqual(model.lockedAnswers, peerAnswers)
        XCTAssertEqual(model.answer(for: questions[0]), "local edit")
        XCTAssertNil(model.answer(for: questions[1]), "an explicit clear must not restore the peer answer")
        XCTAssertEqual(model.answer(for: questions[2]), "peer answer")
        XCTAssertFalse(model.canConfirm)
    }

    func testPeerChoicesRestoreAndAnExplicitlyClearedChoiceStaysEmpty() {
        let questions = [
            ClarifyQuestion(id: "single", question: "Single", choices: ["A", "B"], multiSelect: false),
            ClarifyQuestion(id: "multi", question: "Multi", choices: ["East, US", "West"], multiSelect: true),
            ClarifyQuestion(id: "cleared", question: "Cleared", choices: ["A", "B"], multiSelect: false),
        ]
        let model = BatchClarifyModel(request: request(questions, answers: ["cleared": "A"]))
        model.toggleChoice("A", for: questions[2])
        let multi = #"["East, US","West"]"#
        model.reconcile(request(questions, answers: ["single": "B", "multi": multi, "cleared": "B"]))

        XCTAssertTrue(model.isSelected("B", for: questions[0]))
        XCTAssertEqual(model.stage(for: questions[1]).choices, ["East, US", "West"])
        XCTAssertEqual(model.answer(for: questions[1]), multi)
        XCTAssertNil(model.answer(for: questions[2]))
        XCTAssertFalse(model.canConfirm)
    }

    func testReconciliationRequiresTheSameRequestSessionSocketAndQuestions() {
        let questions = questions(["one", "two"])
        let identity = ServerRequestIdentity(generation: 7, sessionID: "session", id: .string("wire"), method: "clarify")
        let model = BatchClarifyModel(request: request(questions, serverRequest: identity))
        let answers = ["one": "peer"]
        let otherIdentities = [
            ServerRequestIdentity(generation: 8, sessionID: "session", id: .string("wire"), method: "clarify"),
            ServerRequestIdentity(generation: 7, sessionID: "other", id: .string("wire"), method: "clarify"),
            ServerRequestIdentity(generation: 7, sessionID: "session", id: .number(7), method: "clarify"),
            ServerRequestIdentity(generation: 7, sessionID: "session", id: .string("wire"), method: "approval"),
        ]
        for other in otherIdentities {
            model.reconcile(request(questions, answers: answers, serverRequest: other))
        }
        model.reconcile(request(questions, answers: answers, id: "other", serverRequest: identity))
        model.reconcile(request(questions, answers: answers, sessionID: "other", serverRequest: identity))
        model.reconcile(request(Array(questions.reversed()), answers: answers, serverRequest: identity))
        model.reconcile(request(questions, answers: answers))
        XCTAssertTrue(model.lockedAnswers.isEmpty)
        XCTAssertNil(model.answer(for: questions[0]))

        model.reconcile(request(questions, answers: answers, serverRequest: identity))
        XCTAssertEqual(model.answer(for: questions[0]), "peer")
        model.cancel()
        model.reconcile(request(questions, answers: ["one": "too late"], serverRequest: identity))
        XCTAssertEqual(model.answer(for: questions[0]), "peer", "a settled card cannot reopen through a snapshot")
    }

    func testRepeatedAndIncompleteSnapshotsDoNotUndoALocallySentLock() async {
        let questions = questions(["edited", "missing"])
        let original = request(questions, answers: ["edited": "before"])
        let model = BatchClarifyModel(request: original)
        model.setDraft("after", for: questions[0])
        model.setDraft("final", for: questions[1])
        let completed = await model.confirm { qid, _ in qid != "missing" ? receipt() : nil }
        XCTAssertFalse(completed)
        XCTAssertEqual(model.lockedAnswers["edited"], "after")

        model.reconcile(original)
        model.reconcile(request(questions))
        model.reconcile(original)
        XCTAssertEqual(model.lockedAnswers["edited"], "after")
        XCTAssertEqual(model.answer(for: questions[0]), "after")

        var sent: [String] = []
        let retried = await model.confirm { qid, _ in sent.append(qid); return receipt() }
        XCTAssertTrue(retried)
        XCTAssertEqual(sent, ["missing"], "the unchanged stale snapshot must not cause a redundant edited lock")
    }

    func testFailedSendKeepsLocalEditWhenThePeerChangesItsLock() async {
        let questions = questions(["missing", "edited"])
        let model = BatchClarifyModel(request: request(questions, answers: ["edited": "before"]))
        model.setDraft("final", for: questions[0])
        model.setDraft("local", for: questions[1])
        let failed = await model.confirm { _, _ in nil }
        XCTAssertFalse(failed)
        XCTAssertNotNil(model.failure)
        model.reconcile(request(questions, answers: ["edited": "peer"]))
        XCTAssertEqual(model.answer(for: questions[1]), "local")

        var sent: [String] = []
        let retried = await model.confirm { qid, _ in sent.append(qid); return receipt() }
        XCTAssertTrue(retried)
        XCTAssertEqual(sent, ["edited", "missing"])
        XCTAssertNil(model.failure)
    }

    func testPeerLockDuringAwaitIsUpdatedBeforeTheLastMissingAnswer() async throws {
        let questions = questions(["first", "missing", "edited"])
        let model = BatchClarifyModel(request: request(questions))
        for question in questions { model.setDraft("local " + question.id, for: question) }
        var sent: [String] = []
        var serverAnswers: [String: String] = [:]
        var finalAnswers: [String: String]?
        var resumeFirst: CheckedContinuation<Void, Never>?
        let submission = Task { @MainActor in
            await model.confirm { qid, value in
                guard finalAnswers == nil else { return nil }
                sent.append(qid)
                if qid == "first" {
                    await withCheckedContinuation { resumeFirst = $0 }
                }
                serverAnswers[qid] = value
                if serverAnswers.count == questions.count { finalAnswers = serverAnswers }
                return self.receipt()
            }
        }
        let suspended = await waitUntil { resumeFirst != nil }
        guard suspended, let continuation = resumeFirst else {
            submission.cancel()
            return XCTFail("the first send never suspended")
        }
        XCTAssertTrue(model.isSubmitting)
        serverAnswers["edited"] = "peer edit"
        model.reconcile(request(questions, answers: serverAnswers))
        continuation.resume()
        let completed = await submission.value

        XCTAssertTrue(completed)
        XCTAssertEqual(sent, ["first", "edited", "missing"])
        XCTAssertEqual(finalAnswers, ["first": "local first", "edited": "local edited", "missing": "local missing"],
                       "the server completes immediately on the last missing answer, so the edited peer lock must arrive first")
    }

    func testMountedCardReconcilesPeerSnapshotAndKeepsEditedAndClearedFields() throws {
        let questions = questions(["edited", "cleared", "untouched"])
        let state = RequestState(request(questions, answers: ["edited": "before edit", "cleared": "before clear", "untouched": "before peer"]))
        let host = UIHostingController(rootView: MountedCard(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        settle(window)
        let fields = answerFields(in: host.view)
        XCTAssertEqual(fields.count, 3, "the real card must mount its three editable UIKit controls")
        guard fields.count == 3 else { return }
        XCTAssertEqual(fields.map(\.text), ["before edit", "before clear", "before peer"])

        fields[0].replaceText("local edit")
        fields[1].replaceText("")
        settle(window)
        state.request = request(questions, answers: ["edited": "peer edit", "cleared": "peer clear", "untouched": "peer update"])
        settle(window)

        XCTAssertEqual(answerFields(in: host.view).map(\.text), ["local edit", "", "peer update"],
                       "changing the request above an already-mounted @State card must adopt peer data without replacing local drafts")
    }

    func testNewerPeerRevertAfterPartialSendDoesNotRequireAnIntermediateProjection() async {
        let questions = questions(["edited", "missing"])
        let initial = request(questions, answers: ["edited": "A"], sourceRevision: 1)
        let model = BatchClarifyModel(request: initial)
        model.setDraft("B", for: questions[0])
        model.setDraft("final", for: questions[1])
        let partial = await model.confirm { qid, _ in qid == "edited" ? receipt(5) : nil }
        XCTAssertFalse(partial)
        XCTAssertEqual(model.answer(for: questions[0]), "B")

        let reverted = request(questions, answers: ["edited": "A"], sourceRevision: 6)
        XCTAssertNotEqual(initial, reverted, "the same answers must still render when their authority is newer")
        model.reconcile(reverted)
        XCTAssertEqual(model.answer(for: questions[0]), "A")
        XCTAssertEqual(model.lockedAnswers["edited"], "A")
        var sent: [String] = []
        let retried = await model.confirm { qid, _ in sent.append(qid); return receipt(7) }
        XCTAssertTrue(retried)
        XCTAssertEqual(sent, ["missing"])
    }

    func testQueuedProjectionBeforeAcknowledgmentCannotUndoItsAnswerButKeepsOtherPeerAnswers() async {
        let questions = questions(["edited", "other", "missing"])
        let model = BatchClarifyModel(request: request(questions, answers: ["edited": "A", "other": "old"], sourceRevision: 10))
        model.setDraft("B", for: questions[0])
        model.setDraft("final", for: questions[2])
        let partial = await model.confirm { qid, _ in qid == "edited" ? receipt(20) : nil }
        XCTAssertFalse(partial)

        // This snapshot was published before the acknowledgment, but its UI delivery was queued behind it.
        model.reconcile(request(questions, answers: ["edited": "A", "other": "peer"], sourceRevision: 15))
        XCTAssertEqual(model.answer(for: questions[0]), "B")
        XCTAssertEqual(model.answer(for: questions[1]), "peer", "the acknowledgment fences its own answer, not unrelated fields")
        model.reconcile(request(questions, answers: ["edited": "older", "other": "older"], sourceRevision: 14))
        XCTAssertEqual(model.lockedAnswers, ["edited": "B", "other": "peer"])

        model.reconcile(request(questions, answers: ["edited": "B", "other": "latest peer"], sourceRevision: 20))
        XCTAssertEqual(model.answer(for: questions[1]), "latest peer", "a full projection at the acknowledgment revision must still reconcile")
        model.reconcile(request(questions, answers: ["edited": "unversioned"]))
        XCTAssertEqual(model.answer(for: questions[0]), "B")
    }

    func testNewerPeerProjectionBeforeSendReturnsWinsOverTheOlderAcknowledgment() async {
        let questions = questions(["edited", "missing"])
        let model = BatchClarifyModel(request: request(questions, answers: ["edited": "A"], sourceRevision: 10))
        model.setDraft("B", for: questions[0])
        model.setDraft("final", for: questions[1])
        var sent: [String] = []
        let partial = await model.confirm { qid, _ in
            sent.append(qid)
            guard qid == "edited" else { return nil }
            model.reconcile(request(questions, answers: ["edited": "A"], sourceRevision: 30))
            XCTAssertEqual(model.answer(for: questions[0]), "B", "the unsent draft stays until its acknowledgment returns")
            return receipt(20)
        }
        XCTAssertFalse(partial)
        XCTAssertEqual(sent, ["edited", "missing"])
        XCTAssertEqual(model.lockedAnswers["edited"], "A")
        XCTAssertEqual(model.answer(for: questions[0]), "A", "the now-sent draft must adopt the later peer answer")
    }

    func testRevisionedPeerChangesStillPreserveExplicitDraftsAndClears() {
        let questions = questions(["edited", "cleared", "missing"])
        let model = BatchClarifyModel(request: request(questions, answers: ["edited": "A", "cleared": "A"], sourceRevision: 1))
        model.setDraft("local", for: questions[0])
        model.setDraft("", for: questions[1])
        model.setDraft("pending", for: questions[2])
        model.reconcile(request(questions, answers: ["edited": "A", "cleared": "A"], sourceRevision: 3))
        XCTAssertEqual(model.answer(for: questions[0]), "local")
        XCTAssertNil(model.answer(for: questions[1]))
        XCTAssertFalse(model.canConfirm)
    }

    func testMountedCardConsumesARevertWhenTheIntermediateAcknowledgmentProjectionIsCoalesced() async {
        let questions = questions(["edited", "missing"])
        let initial = request(questions, answers: ["edited": "A"], sourceRevision: 1)
        let model = BatchClarifyModel(request: initial)
        model.setDraft("B", for: questions[0])
        model.setDraft("final", for: questions[1])
        let partial = await model.confirm { qid, _ in qid == "edited" ? receipt(5) : nil }
        XCTAssertFalse(partial)
        let state = RequestState(initial)
        let host = UIHostingController(rootView: MountedCard(state: state, model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 1200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        settle(window)
        XCTAssertEqual(answerFields(in: host.view).map(\.text), ["B", "final"])

        // Both parent writes occur without yielding to SwiftUI. Only the final A projection renders; its payload equals initial A.
        state.request = request(questions, answers: ["edited": "B"], sourceRevision: 5)
        state.request = request(questions, answers: ["edited": "A"], sourceRevision: 6)
        XCTAssertEqual(initial.lockedAnswers, state.request.lockedAnswers)
        settle(window)
        XCTAssertEqual(answerFields(in: host.view).map(\.text), ["A", "final"])
        XCTAssertEqual(model.lockedAnswers["edited"], "A")
    }

    private func receipt(_ sourceRevision: Int? = nil) -> ClarifyRespondResult {
        ClarifyRespondResult(status: "ok", remaining: nil, sourceRevision: sourceRevision)
    }

    private func questions(_ ids: [String]) -> [ClarifyQuestion] {
        ids.map { ClarifyQuestion(id: $0, question: $0, choices: [], multiSelect: false) }
    }

    private func request(
        _ questions: [ClarifyQuestion], answers: [String: String] = [:], id: String = "batch",
        sessionID: String = "session", serverRequest: ServerRequestIdentity? = nil, sourceRevision: Int? = nil
    ) -> ClarifyRequestEvent {
        ClarifyRequestEvent(id: id, sessionID: sessionID, question: "", choices: [], multiSelect: false, receivedAt: Date(timeIntervalSince1970: 100),
                            questions: questions, lockedAnswers: answers, serverRequest: serverRequest, sourceRevision: sourceRevision)
    }

    private final class RequestState: ObservableObject {
        @Published var request: ClarifyRequestEvent
        init(_ request: ClarifyRequestEvent) { self.request = request }
    }

    private struct MountedCard: View {
        @ObservedObject var state: RequestState
        var model: BatchClarifyModel? = nil
        var body: some View {
            BatchClarifyCard(request: state.request, deadline: nil, send: { _, _ in ClarifyRespondResult(status: "ok", remaining: nil) }, onConfirmed: {}, onCancelAll: {}, initialModel: model)
                .padding()
        }
    }

    @MainActor
    private enum AnswerField {
        case field(UITextField)
        case view(UITextView)

        var text: String {
            switch self {
            case .field(let field): field.text ?? ""
            case .view(let view): view.text ?? ""
            }
        }

        func replaceText(_ text: String) {
            switch self {
            case .field(let field):
                field.text = text
                field.sendActions(for: .editingChanged)
            case .view(let view):
                view.text = text
                view.delegate?.textViewDidChange?(view)
            }
        }
    }

    private func answerFields(in view: UIView) -> [AnswerField] {
        if let field = view as? UITextField { return [.field(field)] }
        if let textView = view as? UITextView, textView.isEditable { return [.view(textView)] }
        return view.subviews.flatMap { answerFields(in: $0) }
    }

    private func settle(_ window: UIWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()
    }
}

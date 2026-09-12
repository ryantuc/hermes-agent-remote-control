import HermesServeKit
import SwiftUI

/// The four blocking prompts, unified for presentation; they share one sheet but not a wire mechanism, since approvals are session-keyed FIFO with no `request_id`.
enum BlockingPrompt: Identifiable {
    case approval(ApprovalRequestEvent)
    case clarify(ClarifyRequestEvent)
    case sudo(SudoRequestEvent)
    case secret(SecretRequestEvent)

    var id: String {
        switch self {
        case .approval(let request): return "approval-\(request.id.uuidString)"
        case .clarify(let request): return "clarify-\(request.id)"
        case .sudo(let request): return "sudo-\(request.id)"
        case .secret(let request): return "secret-\(request.id)"
        }
    }
}

/// What a presented sheet must do once a decision returns.
enum PromptSheetOutcome: Equatable {
    /// The prompt this sheet is showing still holds the head and must stay answerable.
    case stay
    /// Nothing is waiting, or the head has moved to a prompt this sheet is not showing.
    case dismiss
}

extension BlockingPrompt {
    /// What a sheet showing `self` must do once a decision returns, where `head` is the queue head after the answer landed.
    /// A moved head is not an empty queue: `approval.respond` is positional FIFO, so the prompt this sheet renders is unanswerable once the head advances.
    func sheetOutcome(head: BlockingPrompt?) -> PromptSheetOutcome {
        guard let head else { return .dismiss }
        return head.id == id ? .stay : .dismiss
    }
}

/// Approvals are not optimised for speed: always allow takes an 800 ms hold and a biometric check, and no allow choice is live until an overflowing command has been read to the end.
/// The sheet minimises and never dismisses, and every genuine dismissal path answers explicitly, because silence must never read as consent.
@MainActor
struct ApprovalSheetView: View {
    @Environment(\.hermes) private var t
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppModel.self) private var app
    /// Landscape on a phone: compact height is the signal, because an iPhone is compact width in both orientations.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let prompt: BlockingPrompt
    let serverIdentity: String
    let model: ChatModel
    /// Collapse to the docked bar; does not answer.
    let onMinimise: () -> Void

    @State private var clarifyAnswer = ""
    @State private var sudoPassword = ""
    @State private var secretValue = ""
    @State private var isSubmitting = false

    // The read gate is measured through PreferenceKeys in a named coordinate space because `.onScrollGeometryChange` is iOS 18.
    @State private var commandContentHeight: CGFloat = 0
    @State private var commandContainerHeight: CGFloat = 0
    @State private var commandOffset: CGFloat = 0
    /// Latches once the end of the command has been reached; never re-gates on scroll-up.
    @State private var reachedCommandEnd = false

    /// A command overflows when its natural height exceeds the 190 pt window.
    private var commandOverflows: Bool {
        commandContainerHeight > 0 && commandContentHeight > commandContainerHeight + 1
    }

    /// Satisfied unless the command overflows and has not yet been read to end.
    private var allowsGated: Bool { commandOverflows && !reachedCommandEnd }

    var body: some View {
        VStack(spacing: 0) {
            header
            countdownBar
            ScrollView {
                content
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s6)
                    .padding(.bottom, Space.s9)
            }
            .scrollBounceBehavior(.basedOnSize)
            minimiseBar
        }
        .background(t.surface)
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground(t.surface)
        // The lower layer stays mounted, dims, and does not respond.
        .presentationBackgroundInteraction(.disabled)
        // The only exits are answering or minimising.
        .interactiveDismissDisabled(true)
    }

    /// A fixed detent, never `.medium` / `.large`: a sheet that resizes while you read a command moves the button under your thumb.
    private var detentHeight: CGFloat {
        switch prompt {
        case .approval: return 620
        // A batch asks up to five questions, so it takes the approval sheet's height and the scroller does the rest.
        case .clarify(let request): return request.isBatch ? 620 : 520
        case .sudo, .secret: return 440
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s5) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(headline)
                        .font(HermesFont.title)
                        .foregroundStyle(t.text1)
                    Text(serverIdentity)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s4)
                countdownLabel
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s6)
        .padding(.bottom, Space.s5)
    }

    /// `TimelineView`, not a decrementing counter and not a `Timer`: it recomputes from the wall-clock deadline so it stays correct across a backgrounded app.
    @ViewBuilder
    private var countdownLabel: some View {
        // No deadline, no countdown — see `budget`.
        if budget != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = remainingSeconds(at: context.date)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(RelativeTime.countdown(remaining: remaining))
                        .font(HermesFont.footnote)
                        .hermesNumeric()
                        .foregroundStyle(remaining < 30 ? t.danger : t.warn)
                    Text(expiryConsequence)
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Int(remaining)) seconds remaining, \(expiryConsequence)")
            }
        }
    }

    @ViewBuilder
    private var countdownBar: some View {
        if budget != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(t.stroke3)
                        Rectangle()
                            .fill(remainingSeconds(at: context.date) < 30 ? t.danger : t.warn)
                            .frame(width: geo.size.width * fraction(at: context.date))
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, Space.s6)
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch prompt {
        case .approval(let request): approvalContent(request)
        case .clarify(let request): clarifyContent(request)
        case .sudo: sudoContent
        case .secret(let request): secretContent(request)
        }
    }

    // MARK: Approval

    /// Portrait is one column, landscape two, so the command and every choice stay on screen together in a phone's roughly 430 pt of landscape height.
    @ViewBuilder
    private func approvalContent(_ request: ApprovalRequestEvent) -> some View {
        if isLandscape {
            HStack(alignment: .top, spacing: Space.s6) {
                VStack(alignment: .leading, spacing: Space.s6) {
                    Text(request.description)
                        .font(HermesFont.body)
                        .foregroundStyle(t.text2)
                    commandBlock(request)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: Space.s6) {
                    approvalNotes(request)
                    actions(request)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s6) {
                Text(request.description)
                    .font(HermesFont.body)
                    .foregroundStyle(t.text2)

                commandBlock(request)

                approvalNotes(request)

                actions(request)
            }
        }
    }

    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// The risk line and the read-gate reason, which belong immediately above the ladder in either layout.
    @ViewBuilder
    private func approvalNotes(_ request: ApprovalRequestEvent) -> some View {
        if request.smartDenied {
            riskLine("Smart approvals flagged this as risky, so it cannot be allowed permanently.")
        } else if request.isLikelyDestructive {
            riskLine("This command looks destructive. Read all of it before allowing.")
        }

        if allowsGated {
            // A gated control states its reason above the row.
            Text("Scroll to the end of the command to enable the allow choices.")
                .font(HermesFont.footnote)
                .foregroundStyle(t.warn)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandMaxHeight: CGFloat { 190 }
    private var commandSpace: String { "hermes.command.scroll" }

    /// The exact command, verbatim, monospaced and wrapping, never in a horizontal scroller where a long command can hide.
    private func commandBlock(_ request: ApprovalRequestEvent) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Command")
                .hermesCaption()
                .foregroundStyle(t.text3)

            ScrollView(.vertical, showsIndicators: true) {
                Text(DisplayRedaction.approvalCommand(request.command))
                    .font(HermesFont.code)
                    .foregroundStyle(t.text1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CommandContentKey.self,
                                value: CommandContentMetrics(
                                    height: proxy.size.height,
                                    offset: -proxy.frame(in: .named(commandSpace)).minY
                                )
                            )
                        }
                    )
                    // Read inside the scroll content on purpose: a preference raised within a `ScrollView`'s content does not reach the ScrollView's ancestors on iOS 26.
                    .onPreferenceChange(CommandContentKey.self) { metrics in
                        commandContentHeight = metrics.height
                        commandOffset = metrics.offset
                        updateReadGate()
                    }
            }
            .frame(maxHeight: commandMaxHeight)
            .coordinateSpace(name: commandSpace)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: CommandContainerKey.self, value: proxy.size.height)
                }
            )
            .overlay(alignment: .bottom) { gateVeil }
            .onPreferenceChange(CommandContainerKey.self) { height in
                commandContainerHeight = height
                updateReadGate()
            }
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .enclosure()
    }

    /// Arms `reachedCommandEnd` once the command has been read to the end, and only ever latches true.
    /// `ApprovalReadGate.isRead` answers nil while either measurement is unset, because container and content heights arrive in separate layout passes and an unmeasured content height reads as "it all fits".
    private func updateReadGate() {
        guard let isRead = ApprovalReadGate.isRead(
            containerHeight: Double(commandContainerHeight),
            contentHeight: Double(commandContentHeight),
            offset: Double(commandOffset)
        ), isRead else { return }
        reachedCommandEnd = true
    }

    @ViewBuilder
    private var gateVeil: some View {
        if allowsGated {
            VStack(spacing: Space.s2) {
                Spacer()
                Text("Scroll to the end ▾")
                    .hermesCaption()
                    .foregroundStyle(t.warn)
                    .padding(.bottom, Space.s4)
            }
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [t.enclosure.opacity(0), t.enclosure],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
        }
    }

    private func riskLine(_ text: String) -> some View {
        Text(text)
            .font(HermesFont.subhead)
            .foregroundStyle(t.warn)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ request: ApprovalRequestEvent) -> some View {
        let allows = request.choices.filter { $0 != .deny }
        return VStack(spacing: Space.s4) {
            // Deny + Allow once share a row, stacking above `.accessibilityLarge`; Deny is never gated, because the fail-closed answer must always be reachable.
            if dynamicTypeSize >= .accessibility1 {
                VStack(spacing: Space.s4) {
                    denyButton(request)
                    if allows.contains(.once) { onceButton(request) }
                }
            } else {
                HStack(spacing: Space.s4) {
                    denyButton(request)
                    if allows.contains(.once) { onceButton(request) }
                }
            }

            if allows.contains(.session) {
                Button { submit(request, choice: .session) } label: {
                    Text(ApprovalChoice.session.title)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(allowsGated)
            }

            if allows.contains(.always) {
                // Not an alert: an alert is a second modal asking the same question and cannot express deliberation.
                HoldToConfirmButton("Hold to always allow") {
                    Task { @MainActor in
                        // `confirm` falls back from biometrics to the device passcode, and a device that can evaluate neither fails closed rather than allow-listing on the hold alone.
                        let confirmed = await BiometricConfirmation.confirm(
                            reason: "Confirm adding this command pattern to the backend's permanent allowlist"
                        )
                        guard confirmed else { return }
                        submit(request, choice: .always)
                    }
                }
                .disabled(allowsGated)

                Text("Always allow writes the pattern to your backend's allowlist in config.yaml, for every conversation.")
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(isSubmitting)
    }

    private func denyButton(_ request: ApprovalRequestEvent) -> some View {
        Button { submit(request, choice: .deny) } label: {
            Text(ApprovalChoice.deny.title)
        }
        .buttonStyle(DangerButtonStyle())
    }

    private func onceButton(_ request: ApprovalRequestEvent) -> some View {
        Button { submit(request, choice: .once) } label: {
            Text(ApprovalChoice.once.title)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(allowsGated)
    }

    // MARK: Clarify / sudo / secret

    /// BUG-041: two shapes on one event name, since a batch `clarify.request` carries a `questions` array instead of `question` / `choices` and must be answered per question.
    @ViewBuilder
    private func clarifyContent(_ request: ClarifyRequestEvent) -> some View {
        if request.isBatch {
            BatchClarifyCard(
                request: request,
                deadline: budget.map { $0.received.addingTimeInterval($0.seconds) },
                send: { questionID, answer in
                    await model.lockClarifyAnswer(
                        answer, questionID: questionID, requestID: request.id
                    )
                },
                onConfirmed: {
                    model.finishClarify(requestID: request.id)
                    finishSubmission()
                },
                // Cancel-all is the one path that may omit `question_id`.
                onCancelAll: { answerClarify("") }
            )
            .disabled(isSubmitting)
        } else {
            singleClarifyContent(request)
        }
    }

    private func singleClarifyContent(_ request: ClarifyRequestEvent) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text(request.question)
                .font(HermesFont.body)
                .foregroundStyle(t.text1)
                .textSelection(.enabled)

            // Keyed by offset: `choices` is `[String]` and the backend does not guarantee uniqueness, so `id: \.self` collides.
            ForEach(Array(request.choices.enumerated()), id: \.offset) { _, choice in
                Button { answerClarify(choice) } label: {
                    Text(choice).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            TextField("Your answer", text: $clarifyAnswer, axis: .vertical)
                .font(HermesFont.body)
                .lineLimit(1...5)
                .padding(Space.s5)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            HStack(spacing: Space.s4) {
                Button("Skip") { answerClarify("") }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Send") { answerClarify(clarifyAnswer) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(clarifyAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .disabled(isSubmitting)
    }

    private var sudoContent: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Hermes needs your machine's administrator password to run a privileged command.")
                .font(HermesFont.body)
                .foregroundStyle(t.text1)
            Text("The password goes to your own backend over the encrypted connection and is never stored on this device.")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)

            // Enclosure: this field acts on the machine.
            SecureField("Password", text: $sudoPassword)
                .font(HermesFont.body)
                .textContentType(.password)
                .padding(Space.s5)
                .enclosure()

            HStack(spacing: Space.s4) {
                Button("Skip") { submitSudo("") }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Send") { submitSudo(sudoPassword) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sudoPassword.isEmpty)
            }
        }
        .disabled(isSubmitting)
    }

    private func secretContent(_ request: SecretRequestEvent) -> some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text(request.prompt.isEmpty ? "Hermes needs a credential to continue." : request.prompt)
                .font(HermesFont.body)
                .foregroundStyle(t.text1)
            if !request.envVar.isEmpty {
                Text(request.envVar)
                    .font(HermesFont.code)
                    .foregroundStyle(t.text3)
            }
            Text("Skipping is safe: the tool reports the value as skipped rather than failing.")
                .font(HermesFont.footnote)
                .foregroundStyle(t.text3)

            SecureField("Value", text: $secretValue)
                .font(HermesFont.body)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(Space.s5)
                .enclosure()

            HStack(spacing: Space.s4) {
                Button("Skip") { submitSecret("") }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Save to backend") { submitSecret(secretValue) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(secretValue.isEmpty)
            }
        }
        .disabled(isSubmitting)
    }

    // MARK: Minimise

    /// Minimise, not dismiss: the prompt stays queued and the countdown keeps running, so denial stays an explicit, labelled act.
    private var minimiseBar: some View {
        Button {
            onMinimise()
            dismiss()
        } label: {
            Text("Minimise")
                .font(HermesFont.callout)
                .foregroundStyle(t.text2)
                .frame(maxWidth: .infinity, minHeight: Hit.min)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s6)
        .padding(.bottom, Space.s4)
        .accessibilityHint("Keeps the request open and returns to the transcript")
    }

    // MARK: Submission

    private func submit(_ request: ApprovalRequestEvent, choice: ApprovalChoice) {
        // The `.disabled(isSubmitting)` lands only after the next render, and without this guard a double tap sends two positional `approval.respond` frames, the second answering the next queued approval sight-unseen.
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            await model.respond(to: request, choice: choice)
            isSubmitting = false
            finishSubmission()
        }
    }

    private func answerClarify(_ answer: String) {
        guard !isSubmitting else { return }
        guard case .clarify(let request) = prompt else { return }
        isSubmitting = true
        Task { @MainActor in
            await model.respondClarify(answer, requestID: request.id)
            isSubmitting = false
            finishSubmission()
        }
    }

    private func submitSudo(_ password: String) {
        guard !isSubmitting else { return }
        guard case .sudo(let request) = prompt else { return }
        isSubmitting = true
        Task { @MainActor in
            await model.respondSudo(password, requestID: request.id)
            sudoPassword = ""
            isSubmitting = false
            finishSubmission()
        }
    }

    private func submitSecret(_ value: String) {
        guard !isSubmitting else { return }
        guard case .secret(let request) = prompt else { return }
        isSubmitting = true
        Task { @MainActor in
            await model.respondSecret(value, requestID: request.id)
            secretValue = ""
            isSubmitting = false
            finishSubmission()
        }
    }

    /// A blocking prompt may still hold the head slot when a decision returns, and which one it is decides whether this sheet stays.
    private func finishSubmission() {
        if prompt.sheetOutcome(head: model.currentBlockingPrompt) == .dismiss { dismiss() }
    }

    // MARK: Presentation

    private var headline: String {
        switch prompt {
        case .approval: return "Hermes wants to run a command"
        case .clarify(let request): return request.isBatch ? "Hermes has some questions" : "Hermes has a question"
        case .sudo: return "Administrator password needed"
        case .secret: return "Credential needed"
        }
    }

    private var expiryConsequence: String {
        switch prompt {
        // The backend's own words for what it does at the deadline; it is not a "deny" the user issued.
        case .approval: return "then refused — silence is not consent"
        case .clarify, .secret: return "then skipped"
        case .sudo: return "then cancelled"
        }
    }

    /// The prompt's real, backend-enforced deadline, or nil when there is none and no countdown may be shown.
    /// Approvals do expire even though the gateway emits no `approval.expire` frame: the wait still fails closed after `approvals.timeout` and refuses the tool without telling this client.
    private var budget: (received: Date, seconds: TimeInterval)? {
        switch prompt {
        case .approval(let request):
            return model.approvalBudget(for: request)
        case .clarify(let request):
            // Wire payload first, else the configured `agent.clarify_timeout`, else the kit default.
            let seconds = clarifyTimeoutSeconds(for: request)
            // `<= 0` is the backend's "wait forever", and rendering it as a drained red bar would invent an expiry.
            guard seconds > 0 else { return nil }
            return (request.receivedAt, seconds)
        case .sudo(let request): return (request.receivedAt, request.timeoutSeconds)
        case .secret(let request): return (request.receivedAt, request.timeoutSeconds)
        }
    }

    private func clarifyTimeoutSeconds(for request: ClarifyRequestEvent) -> TimeInterval {
        if let wire = request.wireTimeoutSeconds { return wire }
        if let configured = app.settings.clarifyTimeoutSeconds() { return configured }
        return ClarifyRequestEvent.defaultTimeoutSeconds
    }

    private func remainingSeconds(at date: Date) -> TimeInterval {
        guard let (received, seconds) = budget else { return 0 }
        return max(0, seconds - date.timeIntervalSince(received))
    }

    private func fraction(at date: Date) -> CGFloat {
        guard let (_, seconds) = budget, seconds > 0 else { return 0 }
        return CGFloat(remainingSeconds(at: date) / seconds)
    }
}

// MARK: - Read-gate measurement

private struct CommandContentMetrics: Equatable {
    var height: CGFloat
    var offset: CGFloat
}

private struct CommandContentKey: PreferenceKey {
    static let defaultValue = CommandContentMetrics(height: 0, offset: 0)
    static func reduce(value: inout CommandContentMetrics, nextValue: () -> CommandContentMetrics) {
        value = nextValue()
    }
}

private struct CommandContainerKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

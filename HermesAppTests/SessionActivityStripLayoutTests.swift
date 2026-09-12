import HermesServeKit
import SwiftUI
import UIKit
import XCTest

@testable import HermesMobile

/// **The test BUG-014 needed and did not have.**
///
/// 339 tests were green while the activity strip shipped at ≈424 pt above a
/// 155 pt composer, leaving six lines of conversation on the screen. Nothing
/// caught it because nothing in this project had ever measured a rendered
/// height: the suite asserts on models, and the strip is a view.
///
/// This measures. It hosts the shipped `SessionActivityStrip` in a real
/// `UIWindow` — the same recipe `GrowingComposerFieldTests` uses for the
/// composer — and asks the hosting controller what height the strip takes at a
/// phone width, across the states the wire can actually produce.
///
/// Two properties are pinned, and the second is the one that would have caught
/// the bug outright:
///
/// 1. **A budget.** The resting strip fits in two header lines, whatever it
///    holds.
/// 2. **Invariance.** The resting height of a 12-task, 3-agent session is
///    *identical* to a 1-task, 1-agent one. Height is a function of which groups
///    are present and nothing else — not the item count, and not the length of
///    any string on the wire.
///
/// `measure` deliberately asks for the height the strip WANTS, unconstrained.
/// A test that hands it a fixed frame would measure the frame.
@MainActor
final class SessionActivityStripLayoutTests: XCTestCase {

    /// iPhone 16 Pro portrait width. The narrow phones are wider in points than
    /// this is tall, and the strip's height does not depend on width — every row
    /// is `lineLimit(1)` — so one width is enough to pin the policy.
    private static let width: CGFloat = 393

    /// The resting budget: two groups, one 44 pt line each, plus the container's
    /// top hairline. Nothing on this surface may cost more than the two lines it
    /// is allowed.
    private static let restingBudget: CGFloat = 2 * Hit.min + 2

    // MARK: Measuring

    private func measure(_ activity: SessionActivity) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            SessionActivityStrip(activity: activity)
                .frame(width: Self.width)
        ))
        // Without this the hosting controller adds the screen's safe-area insets
        // to everything it measures — a constant 54 pt on this simulator, which
        // would silently inflate every number in the budget. The strip is a
        // sibling in the middle of `ChatView`'s stack and never sees a safe area
        // of its own.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }

    // MARK: Fixtures

    private func todos(_ count: Int, inProgressAt: Int? = 0, content: String = "Wire the reducer") -> TodoList {
        TodoList(items: (0..<count).map { index in
            TodoItem(
                id: "t\(index)",
                content: "\(content) \(index)",
                status: index == inProgressAt ? .inProgress : (index < (inProgressAt ?? 0) ? .completed : .pending)
            )
        })
    }

    private func agents(_ count: Int, goal: String = "Audit the migration") -> [SubagentRow] {
        (0..<count).map { index in
            SubagentRow(
                id: "sa-\(index)",
                wireSubagentID: "sa-\(index)",
                hasStarted: true,
                goal: "\(goal) \(index)",
                currentTool: "read_file",
                toolCount: index + 1,
                taskIndex: index,
                taskCount: count
            )
        }
    }

    private func activity(todoCount: Int, agentCount: Int) -> SessionActivity {
        var activity = SessionActivity()
        if todoCount > 0 { activity.todos = todos(todoCount) }
        activity.subagents = agents(agentCount)
        return activity
    }

    // MARK: 1 — the budget

    /// Nothing to say, nothing on screen. The strip must not reserve a pixel it
    /// is not using; every point here comes off the transcript.
    func testAnEmptyActivityTakesNoHeightAtAll() {
        XCTAssertEqual(measure(SessionActivity()), 0, accuracy: 0.5,
                       "an empty strip must be invisible, not a blank band above the composer")
    }

    /// The resting state, across every population the wire can produce.
    func testTheRestingStripFitsInTwoHeaderLines() {
        var worst: (state: String, height: CGFloat) = ("none", 0)
        for todoCount in [0, 1, 2, 4, 12] {
            for agentCount in [0, 1, 2, 3] {
                guard todoCount + agentCount > 0 else { continue }
                let height = measure(activity(todoCount: todoCount, agentCount: agentCount))
                if height > worst.height { worst = ("\(todoCount) tasks × \(agentCount) agents", height) }
                XCTAssertLessThanOrEqual(height, Self.restingBudget, """
                    the resting strip is \(height) pt at \(todoCount) tasks × \(agentCount) agents, \
                    over its \(Self.restingBudget) pt budget. This is BUG-014's exact shape: the \
                    strip grows with the wire and the transcript pays for it \
                    (SessionActivityStrip.swift)
                    """)
            }
        }
        // Recorded rather than asserted — the budget above is the contract, and
        // this line is what a future reader needs to fill in a height table
        // without re-deriving it.
        print("[strip] worst resting state: \(worst.state) → \(worst.height) pt")
    }

    // MARK: 2 — invariance, which is the property that broke

    /// **The assertion that would have caught BUG-014.** Twelve tasks and three
    /// agents must rest at exactly the height one task and one agent do.
    func testRestingHeightIsIndependentOfHowMuchIsRunning() {
        let small = measure(activity(todoCount: 1, agentCount: 1))
        for todoCount in [2, 4, 12, 60] {
            for agentCount in [2, 3, 8] {
                let large = measure(activity(todoCount: todoCount, agentCount: agentCount))
                XCTAssertEqual(large, small, accuracy: 0.5, """
                    \(todoCount) tasks × \(agentCount) agents rests at \(large) pt where 1 × 1 rests \
                    at \(small) pt. The strip's resting height must be a function of which groups \
                    exist and nothing else — the moment it tracks the item count, a wide fan-out \
                    eats the transcript
                    """)
            }
        }
    }

    /// …and independent of what the strings say. Every row is `lineLimit(1)`;
    /// a 240-character goal (the kit's clamp) must not wrap into a second line.
    func testHeightIsIndependentOfContentLength() {
        let long = String(repeating: "an extremely long goal that will not fit ", count: 6)
        var wordy = SessionActivity()
        wordy.todos = todos(3, content: long)
        wordy.subagents = agents(2, goal: long)

        XCTAssertEqual(measure(wordy), measure(activity(todoCount: 3, agentCount: 2)), accuracy: 0.5, """
            a long task or goal grew the strip. Rows and the header note are single-line by \
            design — if content can add height, so can the backend
            """)
    }

    /// One group present costs one line, not two: an agent-only session must not
    /// pay for the task header it does not have.
    func testEachGroupCostsOneLineAndOnlyWhenItHasSomethingToSay() {
        let tasksOnly = measure(activity(todoCount: 4, agentCount: 0))
        let agentsOnly = measure(activity(todoCount: 0, agentCount: 3))
        let both = measure(activity(todoCount: 4, agentCount: 3))

        XCTAssertEqual(tasksOnly, agentsOnly, accuracy: 0.5, "the two headers are the same line")
        XCTAssertGreaterThanOrEqual(both, tasksOnly + Hit.min - 1,
                                    "two groups cost two lines")
        XCTAssertLessThanOrEqual(both, Self.restingBudget)
        print("[strip] one group: \(tasksOnly) pt · two groups: \(both) pt")
    }

    // MARK: 3 — the state space, which is the whole of it

    /// **There is no gesture that grows this surface.**
    ///
    /// An inline expansion was built for this wave and measured out of it: two
    /// rows per group is another 176 pt, and with the keyboard up that is
    /// negative transcript on an iPhone SE. So the strip has exactly three
    /// heights, and this enumerates them — a future expansion has to come back
    /// through this test and the budget below it.
    func testTheStripHasExactlyThreeHeights() {
        let heights = Set([
            measure(SessionActivity()),
            measure(activity(todoCount: 4, agentCount: 0)),
            measure(activity(todoCount: 0, agentCount: 3)),
            measure(activity(todoCount: 12, agentCount: 8)),
            measure(activity(todoCount: 1, agentCount: 1)),
        ])
        XCTAssertEqual(heights, [0, Hit.min, 2 * Hit.min], """
            the strip's height must be 0, one line, or two lines and nothing else. \
            Measured: \(heights.sorted())
            """)
    }

    // MARK: 4 — the budget the strip was never sized against

    /// **The arithmetic BUG-014 was missing.** The strip's old cap was reasoned
    /// against the transcript and never against the composer or the keyboard,
    /// which is how a 424 pt strip shipped over a screen it did not fit on.
    ///
    /// This measures both halves at once and computes what is left for the
    /// conversation on the phones this app runs on. The numbers it prints are
    /// the height budget table; the assertion is the floor beneath it.
    func testThereIsStillAConversationLeftUnderTheStripAndComposer() async throws {
        let harness = await AppHarness.make()
        let chat = harness.chat(storedID: "20260815_120000_layout")
        let composer = measureComposer(chat: chat, app: harness.app)
        let strip = measure(activity(todoCount: 4, agentCount: 3))

        // screen height, top safe area, bottom safe area, portrait keyboard
        let phones: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("iPhone SE (3rd gen)", 667, 20, 0, 291),
            ("iPhone 16 Pro", 852, 59, 34, 336),
            ("iPhone 16 Pro Max", 932, 59, 34, 346),
        ]
        let navigationBar: CGFloat = 44
        let lineHeight: CGFloat = 21

        print("[budget] composer \(composer) pt · strip \(strip) pt")
        for (name, screen, top, bottom, keyboard) in phones {
            for (posture, chrome) in [("keyboard up", keyboard), ("keyboard down", bottom)] {
                let fixed = top + navigationBar + chrome + composer
                let transcript = screen - fixed - strip
                print("""
                    [budget] \(name), \(posture): transcript \(transcript) pt \
                    (\(Int(transcript / lineHeight)) lines)
                    """)
                // Three lines is the floor, and the SE with the keyboard up is
                // the state that sets it: 667 pt of screen minus a 291 pt
                // keyboard, a 44 pt bar and a 155.7 pt composer leaves 156 pt
                // for everything else. The strip's whole 88 pt share of that is
                // why it is a header — the 424 pt version left MINUS 268 pt, and
                // any inline expansion puts it back under water.
                XCTAssertGreaterThan(transcript, 3 * lineHeight, """
                    \(name) with the \(posture) leaves \(transcript) pt of transcript under a \
                    \(strip) pt strip and a \(composer) pt composer — under three lines of \
                    conversation. That is the state BUG-014 was reported in
                    """)
            }
        }

        await harness.tearDown()
    }

    /// The composer at rest — empty field, no attachments, portrait.
    private func measureComposer(chat: ChatModel, app: AppModel) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(
            ComposerView(model: chat)
                .environment(app)
                .frame(width: Self.width)
        ))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
        window.isHidden = true
        return size.height
    }
}

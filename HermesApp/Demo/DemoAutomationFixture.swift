import Foundation
import HermesServeKit

/// Which of the activity strip's sheets the screenshot harness presents over a seeded chat.
struct HarnessStripSheet: Identifiable {
    enum Kind { case automation, processes }
    let kind: Kind
    let chat: ChatModel
    var id: String { kind == .automation ? "automation" : "processes" }
}

extension ChatModel {
    /// Screenshot harness: every kind of automation at once, in the states that exercise the most wording, plus a running and a finished background process. Shapes follow the contracts the kit decodes.
    func seedDemoAutomation() {
        let now = Date()
        sessionControls.seed(SessionControlSnapshot(
            goal: GoalSnapshot(
                title: "Get the release notes reviewed and the 0.2.0 tag pushed",
                status: "active",
                turnsUsed: 3,
                maxTurns: 20,
                contract: GoalContract(outcome: "Release notes approved by a reviewer and the tag on origin", verification: "git tag --list shows 0.2.0 and the PR is approved", stopWhen: "The tag is pushed"),
                subgoals: ["Changelog reviewed", "Tag pushed"],
                gates: [],
                createdAt: now.addingTimeInterval(-1_800),
                updatedAt: now.addingTimeInterval(-120),
                lastVerdict: "continue",
                lastReason: "Notes drafted; waiting for the review window",
                waitBarrier: .until(now.addingTimeInterval(1_500), reason: "Reviewer is out until 15:00")
            ),
            loop: LoopSnapshot(
                prompt: "Check whether the deploy to staging finished and report the result",
                status: "active",
                mode: "interval",
                intervalSeconds: 1_800,
                currentDelay: 1_800,
                times: 6,
                ticksFired: 2,
                createdAt: now.addingTimeInterval(-3_700),
                lastFiredAt: now.addingTimeInterval(-900),
                nextDueAt: now.addingTimeInterval(900),
                deferredByGoal: true
            ),
            heartbeat: HeartbeatSnapshot(
                prompt: "Anything new in the support inbox that needs a reply today?",
                status: "paused",
                intervalSeconds: 3_600,
                createdAt: now.addingTimeInterval(-7_300),
                lastFiredAt: now.addingTimeInterval(-3_650),
                fireCount: 2
            ),
            revision: "fixture",
            updatedAt: now.addingTimeInterval(-120)
        ))
        backgroundProcesses.seed([
            BackgroundProcess(
                id: "proc_7f3a",
                command: "npm run dev",
                cwd: "/Users/you/Projects/harc-site",
                pid: 48_213,
                startedAt: "2026-10-09T16:40:12",
                uptimeSeconds: 1_275,
                status: "running",
                outputPreview: "ready on http://localhost:5173",
                outputTail: "VITE v5.4.2  ready in 412 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host to expose\n[hmr] update /src/App.tsx"
            ),
            BackgroundProcess(
                id: "proc_0c91",
                command: "pytest -q tests/",
                cwd: "/Users/you/Projects/harc-site",
                pid: 48_001,
                startedAt: "2026-10-09T16:38:02",
                uptimeSeconds: 41,
                status: "exited",
                outputPreview: "12 passed in 38.90s",
                outputTail: "............\n12 passed in 38.90s",
                exitCode: 0,
                exitedAt: now.addingTimeInterval(-600),
                completionReason: "exited"
            ),
        ])
    }
}

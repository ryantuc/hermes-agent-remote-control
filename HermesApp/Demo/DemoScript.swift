import Foundation
import HermesServeKit

/// The canned content the demo replays: content only, with `DemoBackend` owning the replay and `AppModel.enterDemo()` the entry.
///
/// Every string is deliberately benign: no real person, machine, backend address or filesystem.
///
/// Every beat list is built by appending, never a chain of `+`: a concatenation of literal enum arrays makes the type checker give up outright.
enum DemoScript {

    /// One beat of a replay: a pause, or one gateway event pushed onto the socket as a live backend would.
    ///
    /// The pauses are small, deterministic, and the only timing in the whole feature.
    enum Beat: Sendable {
        case pause(TimeInterval)
        case event(String, JSONValue)

        static func event(_ type: String) -> Beat { .event(type, .null) }
    }

    /// A whole turn: the prompt that provokes it and the frames it produces.
    struct Turn: Sendable {
        let prompt: String
        let beats: [Beat]
    }

    // MARK: The model and workspace the demo claims to be running

    /// Named so nobody reads it as a real deployment; shown in the model pill and the session subtitle.
    static let modelName = "hermes-demo"
    static let providerName = "demo"
    /// The working directory the demo's chips show: a plausible path that is obviously a sample.
    static let workingDirectory = "/demo/notes"
    static let sessionTitle = "What is Hermes Agent?"

    /// `_session_info` as the app reads it, for every canned answer that carries one.
    static func info(title: String = sessionTitle) -> JSONValue {
        .object([
            "model": .string(modelName),
            "provider": .string(providerName),
            "cwd": .string(workingDirectory),
            "title": .string(title),
            "desktop_contract": .number(5),
            "running": .bool(false),
        ])
    }

    // MARK: Turn one — "What is Hermes Agent?"

    static let turnOne = Turn(prompt: "What is Hermes Agent?", beats: turnOneBeats())

    private static func turnOneBeats() -> [Beat] {
        var beats: [Beat] = []
        beats.append(.pause(0.35))
        beats.append(.event("message.start"))
        beats.append(.pause(0.3))
        beats += reasoning([
            "The question is about the product itself, so the answer should say what runs where. ",
            "Worth being concrete about the split: the agent runs on the person's own machine, ",
            "and this app is a client that talks to it. Keep it to a short paragraph.",
        ])
        beats.append(.pause(0.5))
        beats += streaming([
            "**Hermes Agent** is a coding and research agent that runs on your own computer or server.\n\n",
            "You start it there with `hermes serve`, and it does the work in your own files, ",
            "with your own model credentials, in your own shell.\n\n",
            "This app is a **remote client** for it. It shows the conversation, the agent's ",
            "thinking, every tool call it makes and every step of its plan — and it asks you ",
            "first whenever your backend's approval policy requires it. The agent still runs ",
            "on your own machine, and that machine decides which AI providers and tools see ",
            "your requests.",
        ])
        beats.append(.pause(0.4))
        beats.append(.event("message.complete", .object([
            "text": .string(turnOneAnswer),
            "status": .string("complete"),
        ])))
        beats.append(.event("session.info", info()))
        return beats
    }

    static let turnOneAnswer = """
        **Hermes Agent** is a coding and research agent that runs on your own computer or server.

        You start it there with `hermes serve`, and it does the work in your own files, with your \
        own model credentials, in your own shell.

        This app is a **remote client** for it. It shows the conversation, the agent's thinking, \
        every tool call it makes and every step of its plan — and it asks you first whenever your \
        backend's approval policy requires it. The agent still runs on your own machine, and that \
        machine decides which AI providers and tools see your requests.
        """

    // MARK: Turn two — "Okay, write up the report."

    /// The plan the second turn works through, in four steps so the activity strip has a real fraction to climb.
    static let planSteps = [
        "Read the overview note",
        "Search the sample docs for the feature list",
        "Draft the summary",
        "Save it as a markdown file",
    ]

    static let turnTwo = Turn(prompt: "Okay, write up the report.", beats: turnTwoBeats())

    private static func turnTwoBeats() -> [Beat] {
        var beats: [Beat] = []
        beats.append(.pause(0.35))
        beats.append(.event("message.start"))
        beats.append(.pause(0.3))
        beats += reasoning([
            "A short written report, then. Four steps: read the note that is already here, ",
            "check the sample docs for anything the note misses, draft it, and save it ",
            "next to the note so it can be read later.",
        ])
        beats.append(.pause(0.45))
        // The plan lands first, so the strip has something to count.
        beats += todoUpdate(inProgress: 0, completed: 0)
        beats.append(.pause(0.5))
        beats += tool(
            id: "demo-tool-1",
            name: "read_file",
            context: "notes/hermes-overview.md",
            runningFor: 0.9,
            result: readNoteResult,
            durationSeconds: 0.9
        )
        beats += todoUpdate(inProgress: 1, completed: 1)
        beats.append(.pause(0.4))
        beats += tool(
            id: "demo-tool-2",
            name: "search",
            context: "docs/ — approval",
            runningFor: 1.1,
            result: searchResult,
            durationSeconds: 1.1
        )
        beats += todoUpdate(inProgress: 2, completed: 2)
        beats.append(.pause(0.45))
        beats += streaming(["Here is the write-up.\n\n"])
        beats += todoUpdate(inProgress: 3, completed: 3)
        beats.append(.pause(0.35))
        beats += tool(
            id: "demo-tool-3",
            name: "write_file",
            context: "notes/hermes-report.md",
            runningFor: 0.8,
            result: "Wrote notes/hermes-report.md (18 lines).",
            durationSeconds: 0.8,
            inlineDiff: reportDiff
        )
        beats += todoUpdate(inProgress: nil, completed: 4)
        beats.append(.pause(0.4))
        beats += streaming(turnTwoReportChunks)
        beats.append(.pause(0.4))
        beats.append(.event("message.complete", .object([
            "text": .string(turnTwoFullAnswer),
            "status": .string("complete"),
        ])))
        beats.append(.event("session.info", info(title: "Hermes Agent write-up")))
        return beats
    }

    static let readNoteResult = """
        # Hermes overview

        Hermes Agent runs on the machine you start it on. Clients connect to it over a websocket \
        and watch the same session.

        - the agent does the work locally
        - clients render the transcript, the plan and the tool calls
        - anything dangerous asks first
        """

    static let searchResult = """
        docs/approvals.md:4   the approval policy decides what pauses for an answer
        docs/approvals.md:19  the choices are deny, once, this session, always
        docs/clients.md:31    approvals reach every connected client at once
        3 matches in 2 files
        """

    static let reportDiff = """
        --- a/notes/hermes-report.md
        +++ b/notes/hermes-report.md
        @@ -0,0 +1,6 @@
        +# Hermes Agent — what it is
        +
        +Hermes Agent runs on your own machine. Clients are windows onto it.
        +
        +- the agent works locally, in your files, with your credentials
        +- your approval policy decides what pauses for your answer
        """

    static let turnTwoReportChunks = [
        "# Hermes Agent — what it is\n\n",
        "Hermes Agent runs on the machine you start it on. It reads and writes files there, ",
        "runs commands there, and uses the model credentials stored there.\n\n",
        "## How the clients fit\n\n",
        "A client — this app, or the desktop app — connects over a websocket and watches the ",
        "same session. Several can watch at once, and they all see the same transcript, the ",
        "same plan and the same tool calls as they happen.\n\n",
        "## Safety\n\n",
        "Where your approval policy calls for it, a dangerous action stops and asks. The answer ",
        "is yours: deny it, allow it once, allow it for this session, or allow it always.\n\n",
        "| Surface | Where it runs |\n| --- | --- |\n",
        "| The agent | your machine |\n| Your files and credentials | your machine |\n",
        "| This app | your phone, as a window onto it |\n\n",
        "Saved to `notes/hermes-report.md`.\n",
    ]

    static let turnTwoReport = turnTwoReportChunks.joined()

    /// What `message.complete` carries: the preamble the turn streamed before its tool calls, then the report.
    static let turnTwoFullAnswer = "Here is the write-up.\n\n" + turnTwoReport

    // MARK: Anything the reviewer types themselves

    /// It has to be honest about being canned rather than invent an answer to a real question.
    static let freeformReply = """
        This is a canned demo, so the answer to that one is not really mine to give — nothing here \
        is connected to a running agent.

        What the demo does show is real: the transcript, the thinking, the plan, the tool cards and \
        the approval prompts are the same views a live session draws. Connect your own \
        `hermes serve` from Settings → Backend and every one of them fills with your machine's work \
        instead of this script's.
        """

    static let freeformTurn = Turn(prompt: "", beats: freeformBeats())

    private static func freeformBeats() -> [Beat] {
        var beats: [Beat] = []
        beats.append(.pause(0.3))
        beats.append(.event("message.start"))
        beats.append(.pause(0.3))
        beats += streaming([
            "This is a canned demo, so the answer to that one is not really mine to give — ",
            "nothing here is connected to a running agent.\n\n",
            "What the demo does show is real: the transcript, the thinking, the plan, the tool ",
            "cards and the approval prompts are the same views a live session draws. Connect ",
            "your own `hermes serve` from Settings → Backend and every one of them fills with ",
            "your machine's work instead of this script's.",
        ])
        beats.append(.pause(0.3))
        beats.append(.event("message.complete", .object([
            "text": .string(freeformReply),
            "status": .string("complete"),
        ])))
        return beats
    }

    /// The turn a given prompt provokes.
    ///
    /// BUG-103: selecting on the prompt is order-free, so a message a reviewer types cannot shift the scripted turns down a slot.
    static func turn(forPrompt prompt: String) -> Turn {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitive because the composer is the real one and iOS autocapitalisation is on.
        switch trimmed.lowercased() {
        case turnOne.prompt.lowercased(): return turnOne
        case turnTwo.prompt.lowercased(): return turnTwo
        default: return freeformTurn
        }
    }

    /// The scripted turns the autoplay driver sends, in order.
    static let autoplayTurns = [turnOne, turnTwo]

    /// The `index`-th autoplay turn.
    static func autoplayTurn(_ index: Int) -> Turn {
        autoplayTurns[min(max(index, 0), autoplayTurns.count - 1)]
    }

    /// How many scripted turns play on their own before the composer is the only way to produce another.
    static let autoplayTurnCount = autoplayTurns.count

    // MARK: Beat builders

    /// A thinking trace, delivered as deltas so the disclosure fills the way a real one does.
    static func reasoning(_ chunks: [String]) -> [Beat] {
        var beats: [Beat] = []
        for chunk in chunks {
            beats.append(.event("reasoning.delta", .object(["text": .string(chunk)])))
            beats.append(.pause(0.28))
        }
        return beats
    }

    /// Streamed assistant text.
    static func streaming(_ chunks: [String]) -> [Beat] {
        var beats: [Beat] = []
        for chunk in chunks {
            beats.append(.event("message.delta", .object(["text": .string(chunk)])))
            beats.append(.pause(0.22))
        }
        return beats
    }

    /// One tool call: a start frame, time on screen while it runs, and a complete frame carrying its output.
    static func tool(
        id: String,
        name: String,
        context: String,
        runningFor: TimeInterval,
        result: String,
        durationSeconds: Double,
        inlineDiff: String = ""
    ) -> [Beat] {
        var complete: [String: JSONValue] = [
            "tool_id": .string(id),
            "name": .string(name),
            "result": .string(result),
            "duration_s": .number(durationSeconds),
        ]
        if !inlineDiff.isEmpty { complete["inline_diff"] = .string(inlineDiff) }
        var beats: [Beat] = []
        beats.append(.event("tool.start", .object([
            "tool_id": .string(id),
            "name": .string(name),
            "context": .string(context),
        ])))
        beats.append(.pause(runningFor))
        beats.append(.event("tool.complete", .object(complete)))
        beats.append(.pause(0.3))
        return beats
    }

    /// A whole-list `todo` update in the shape the real tool emits, start frame and all, which is what moves the activity strip and the checklist.
    static func todoUpdate(inProgress: Int?, completed: Int) -> [Beat] {
        var items: [JSONValue] = []
        for (index, content) in planSteps.enumerated() {
            let status: String
            if index < completed {
                status = "completed"
            } else if index == inProgress {
                status = "in_progress"
            } else {
                status = "pending"
            }
            items.append(.object([
                "id": .string("demo-todo-\(index + 1)"),
                "content": .string(content),
                "status": .string(status),
            ]))
        }
        let toolID = "demo-todo-call-\(completed)"
        var beats: [Beat] = []
        beats.append(.event("tool.start", .object([
            "tool_id": .string(toolID),
            "name": .string(TodoList.toolName),
            "context": .string("update plan"),
        ])))
        beats.append(.pause(0.2))
        beats.append(.event("tool.complete", .object([
            "tool_id": .string(toolID),
            "name": .string(TodoList.toolName),
            "todos": .array(items),
            "duration_s": .number(0.1),
        ])))
        return beats
    }

    // MARK: The history rows the hub shows while the demo is on

    /// Two rows in the drawer, plainly labelled as the demo's, so the history surface is representative rather than empty.
    static func historyRows() -> [SessionSummary] {
        let now = Date().timeIntervalSince1970
        var rows: [SessionSummary] = []
        rows.append(summary(
            id: "demo-thread-1",
            title: "What is Hermes Agent?",
            preview: "Hermes Agent runs on your own computer or server.",
            lastActive: now
        ))
        rows.append(summary(
            id: "demo-thread-2",
            title: "Sample: tidy up the notes folder",
            preview: "Renamed three files and left the rest alone.",
            lastActive: now - 5_400
        ))
        return rows
    }

    private static func summary(
        id: String,
        title: String,
        preview: String,
        lastActive: TimeInterval
    ) -> SessionSummary {
        SessionSummary(json: .object([
            "id": .string(id),
            "title": .string(title),
            "preview": .string(preview),
            "model": .string(modelName),
            "source": .string("demo"),
            "last_active": .number(lastActive),
            "message_count": .number(4),
        ]))
    }
}

import XCTest

@testable import HermesServeKit

/// `tool.output_risk` — the backend's safety signal about a tool's output.
///
/// Every assertion here is about *not dropping it*. The findings are relayed
/// verbatim (the client never rewords a safety finding), and the ways this
/// signal used to go missing — a band with no findings, a card whose id was
/// synthesised, a risk that outran its card — are each pinned below.
final class OutputRiskTests: XCTestCase {
    private let session = "a1b2c3d4"

    private func runFixture() throws -> SessionTurnState {
        let engine = TurnEngine()
        for event in try Fixtures.events("tool-output-risk") { engine.apply(event) }
        engine.flush()
        return engine.state(for: session)
    }

    private func tool(_ state: SessionTurnState, named name: String) throws -> ToolActivity {
        try XCTUnwrap(state.entries.compactMap(\.tool).first { $0.name == name })
    }

    /// The easy case, plus `redacted` — which the client decoded and then threw
    /// away. "Some of this output was withheld" is a signal in its own right.
    func testFindingsBandAndRedactionAllReachTheCard() throws {
        let terminal = try tool(try runFixture(), named: "terminal")

        XCTAssertEqual(
            terminal.outputRiskFindings,
            ["Output contains an instruction to exfiltrate ~/.ssh/id_rsa"],
            "findings are relayed verbatim"
        )
        XCTAssertEqual(terminal.outputRisk, "high")
        XCTAssertTrue(terminal.outputRiskRedacted)
        XCTAssertTrue(terminal.hasOutputRisk)
        XCTAssertFalse(terminal.isRunning, "the later tool.complete still closed the card")
    }

    /// A band with an empty `findings` list is not an empty event: the scan
    /// rated the output and the user has to see the rating.
    func testABandWithNoFindingsIsStillSurfaced() throws {
        let readFile = try tool(try runFixture(), named: "read_file")

        XCTAssertTrue(readFile.outputRiskFindings.isEmpty)
        XCTAssertEqual(readFile.outputRisk, "medium")
        XCTAssertTrue(readFile.hasOutputRisk, "an empty findings list must not drop the whole event")
    }

    /// That same `read_file` card proves the correlation fix: it was opened by
    /// a `tool.start` with **no** `tool_id`, so it holds a synthetic
    /// `live-tool:` id that the risk event's real `call_9` can never match.
    /// Exact-id-only correlation dropped this silently.
    func testRiskCorrelatesByNameWhenTheCardHasASyntheticID() throws {
        let state = try runFixture()
        let readFile = try tool(state, named: "read_file")

        XCTAssertTrue(
            readFile.id.hasPrefix("live-tool:"),
            "precondition: a tool.start with no id gets a synthetic one"
        )
        XCTAssertNotEqual(readFile.id, "call_9")
        XCTAssertEqual(readFile.outputRisk, "medium", "the band still found its card by name")
    }

    /// With tool progress off there is no `tool.start`, so the risk event
    /// arrives before any card exists. It is held and attached when the card
    /// appears at `tool.complete`, rather than being dropped on the floor.
    func testRiskThatArrivesBeforeItsCardIsHeldNotDropped() throws {
        let webFetch = try tool(try runFixture(), named: "web_fetch")

        XCTAssertEqual(
            webFetch.outputRiskFindings,
            ["The page asks the agent to ignore its instructions"]
        )
        XCTAssertEqual(webFetch.outputRisk, "high")
    }

    /// The all-empty event is the "scanned, found nothing" shape. It must not
    /// register as a risk — and, arriving late for a tool that *was* flagged,
    /// must not wipe the warning already on that card.
    func testAnEmptyRiskEventChangesNothing() throws {
        let state = try runFixture()

        let terminal = try tool(state, named: "terminal")
        XCTAssertFalse(
            terminal.outputRiskFindings.isEmpty,
            "the trailing empty event must not clear a finding the user was already shown"
        )
        XCTAssertEqual(terminal.outputRisk, "high")

        let clean = ToolActivity(id: "call_3", name: "read_file")
        XCTAssertFalse(clean.hasOutputRisk, "a card with no signal renders no risk band")
    }

    /// A held signal is bounded: a session that never materialises the matching
    /// cards cannot grow the hold queue without limit.
    func testHeldRisksAreBounded() throws {
        let engine = TurnEngine()
        for index in 0..<40 {
            engine.apply(GatewayEvent(
                type: "tool.output_risk",
                sessionID: session,
                payload: .object([
                    "tool_id": .string("call_\(index)"),
                    "name": .string("ghost_\(index)"),
                    "risk": .string("high"),
                ]),
                params: .null
            ))
        }
        // Only the most recent held signals survive; the one that just arrived
        // is still the one that matters, and it still lands.
        engine.apply(GatewayEvent(
            type: "tool.complete",
            sessionID: session,
            payload: .object(["tool_id": .string("call_39"), "name": .string("ghost_39")]),
            params: .null
        ))
        let tools = engine.state(for: session).entries.compactMap(\.tool)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].outputRisk, "high")

        // …while a signal long since evicted no longer attaches.
        engine.apply(GatewayEvent(
            type: "tool.complete",
            sessionID: session,
            payload: .object(["tool_id": .string("call_0"), "name": .string("ghost_0")]),
            params: .null
        ))
        let evicted = try tool(engine.state(for: session), named: "ghost_0")
        XCTAssertFalse(evicted.hasOutputRisk)
    }

    /// The projection itself: `name` is on the wire and the client needs it,
    /// and `hasSignal` is what separates "nothing found" from "not reported".
    func testProjectionKeepsEveryFieldOfTheWireEvent() throws {
        let events = try Fixtures.events("tool-output-risk")
        guard case .toolOutputRisk(let risk) = HermesEvent.project(events[1]) else {
            return XCTFail("expected .toolOutputRisk")
        }
        XCTAssertEqual(risk.toolID, "call_1")
        XCTAssertEqual(risk.name, "terminal")
        XCTAssertEqual(risk.risk, "high")
        XCTAssertTrue(risk.redacted)
        XCTAssertTrue(risk.hasSignal)

        let quiet = ToolOutputRiskEvent(
            sessionID: session, toolID: "call_1", name: "terminal",
            risk: "", findings: [], redacted: false
        )
        XCTAssertFalse(quiet.hasSignal)

        let redactionOnly = ToolOutputRiskEvent(
            sessionID: session, toolID: "call_1", name: "terminal",
            risk: "", findings: [], redacted: true
        )
        XCTAssertTrue(redactionOnly.hasSignal, "a redaction with no band is still worth showing")
    }

    /// The event is turn-scoped, so an unscoped one belongs to the pinned
    /// session rather than to whatever chat is on screen.
    func testRiskIsTurnScoped() {
        XCTAssertTrue(HermesEvent.turnScopedEventTypes.contains("tool.output_risk"))

        let engine = TurnEngine()
        engine.apply(GatewayEvent(type: "message.start", sessionID: session, payload: .null, params: .null))
        engine.apply(GatewayEvent(
            type: "tool.start",
            sessionID: session,
            payload: .object(["tool_id": .string("call_1"), "name": .string("terminal")]),
            params: .null
        ))
        let routed = engine.apply(GatewayEvent(
            type: "tool.output_risk",
            sessionID: "",
            payload: .object([
                "tool_id": .string("call_1"), "name": .string("terminal"), "risk": .string("high"),
            ]),
            params: .null
        ))
        XCTAssertEqual(routed, session)
        XCTAssertEqual(engine.state(for: session).entries.compactMap(\.tool).first?.outputRisk, "high")
    }
}

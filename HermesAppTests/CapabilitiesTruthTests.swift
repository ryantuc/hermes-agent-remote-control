import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-090 — the Capabilities Skills and Tools tabs implied more than the backend does.
///
/// Two gaps. (A) A Skills or Tools toggle is a config write the backend reads when it next builds an agent (`PUT /api/skills/toggle` saves the disabled set; `PUT /api/tools/toolsets/{name}` saves `platform_toolsets`), so a conversation already running keeps what it started with. Only the MCP tab said so; Skills and Tools looked like live switches. (B) `GET /api/tools/toolsets` marks every row `configured` (`_toolset_has_keys`, `hermes_cli/web_routers/tools.py`) to separate "enabled" from "can actually run", and the desktop draws "Needs keys" from it; the phone dropped the field, so a toolset switched on without its keys read as working while its tools never loaded.
///
/// Asserted on the decode and the two copy functions the screen calls, not by hosting the screen: hosting needs a REST fixture the offline harness does not have.
@MainActor
final class CapabilitiesTruthTests: XCTestCase {

    /// The live payload: a bare array of rows keyed `name` (`get_toolsets`).
    private func rows(_ json: JSONValue) -> [CapabilitiesView.ToolsetRow] {
        CapabilitiesView.toolsetRows(from: json)
    }

    // MARK: (B) configured

    func testAToolsetSwitchedOnWithoutItsKeysSaysSo() {
        let decoded = rows([
            ["name": "web", "label": "Web Search", "description": "Search the web", "enabled": true, "configured": false],
        ])
        guard let web = decoded.first else { return XCTFail("the row did not decode") }

        XCTAssertNotNil(CapabilitiesView.setupNote(for: web), """
            the backend reported web as enabled but not configured, and the row says nothing: \
            it reads as working while its tools never load (BUG-090)
            """)
    }

    func testAToolsetThatIsOffAndUnconfiguredAlsoSaysSo() {
        let decoded = rows([
            ["name": "image_gen", "label": "Image Generation", "description": "", "enabled": false, "configured": false],
        ])
        guard let row = decoded.first else { return XCTFail("the row did not decode") }

        XCTAssertNotNil(CapabilitiesView.setupNote(for: row), "turning this on will not load its tools either, and the row is where the user decides")
    }

    func testAConfiguredToolsetSaysNothingExtra() {
        let decoded = rows([
            ["name": "terminal", "label": "Terminal", "description": "Run commands", "enabled": true, "configured": true],
        ])
        guard let row = decoded.first else { return XCTFail("the row did not decode") }

        XCTAssertNil(CapabilitiesView.setupNote(for: row))
    }

    func testABackendThatSendsNoConfiguredFlagIsNotAccusedOfMissingKeys() {
        // Older backends never sent the field; absence is unknown, not "missing keys".
        let decoded = rows(["toolsets": [["key": "web", "label": "Web", "enabled": true]]])
        guard let row = decoded.first else { return XCTFail("the legacy {toolsets: [{key}]} shape stopped decoding") }

        XCTAssertEqual(row.key, "web")
        XCTAssertNil(CapabilitiesView.setupNote(for: row))
    }

    // MARK: (A) when a toggle bites

    func testSkillsAndToolsSayTheirTogglesTakeEffectOnTheNextSession() {
        for tab in ["Skills", "Tools"] {
            let note = CapabilitiesView.timingNote(for: tab)
            XCTAssertNotNil(note, "the \(tab) tab says nothing about when a toggle takes effect, so it reads as a live switch on the running turn (BUG-090)")
            XCTAssertTrue(note?.localizedCaseInsensitiveContains("next session") == true, "\(tab): \(String(describing: note))")
        }
    }

    func testMCPKeepsItsOwnSentence() {
        let note = CapabilitiesView.timingNote(for: "MCP")
        XCTAssertTrue(note?.localizedCaseInsensitiveContains("next session") == true)
        XCTAssertTrue(note?.contains("desktop or in the CLI") == true)
    }

    func testTheHubTabMakesNoTimingClaim() {
        // Installing is an action with its own progress and rollback, not a toggle.
        XCTAssertNil(CapabilitiesView.timingNote(for: "Hub"))
    }
}

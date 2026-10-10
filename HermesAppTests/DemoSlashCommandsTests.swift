import HermesServeKit
import XCTest

@testable import HermesMobile

/// FEAT-020 polish: the demo shows the slash-command surface.
///
/// Typing `/` in the demo drew nothing: `DemoBackend` answered `commands.catalog` and `complete.slash` with the empty object it gives every method it does not know, which the client reads as a gateway with no commands. The demo is the App Store reviewer's whole view of the app, so the completion list FEAT-040 built has to be on it, with commands HARC actually runs.
final class DemoSlashCommandsTests: XCTestCase {

    private func complete(_ text: String) async -> SlashCompletionResult {
        let backend = DemoBackend()
        let reply = await backend.answer(method: "complete.slash", params: .object([
            "text": .string(text),
            "session_id": .string(DemoBackend.runtimeSessionID),
        ]))
        return SlashCompletionResult(json: reply)
    }

    private func catalog() async -> SlashCommandCatalog {
        let backend = DemoBackend()
        return SlashCommandCatalog(json: await backend.answer(method: "commands.catalog", params: .object([
            "session_id": .string(DemoBackend.runtimeSessionID),
        ])))
    }

    /// A bare `/` lists commands, the way a real gateway browses its catalog.
    func testASlashInTheDemoListsCommands() async {
        let items = await complete("/").items
        XCTAssertGreaterThanOrEqual(items.count, 3, "typing / in the demo listed \(items.count) commands")
        XCTAssertTrue(items.allSatisfy { !$0.meta.isEmpty }, "every demo command carries the one-line description the list shows beside it")
    }

    /// A prefix narrows the list, so the list visibly answers the typing.
    func testAPrefixNarrowsTheList() async {
        let all = await complete("/").items
        let narrowed = await complete("/st").items
        XCTAssertFalse(narrowed.isEmpty, "/st matched nothing in the demo")
        XCTAssertLessThan(narrowed.count, all.count, "/st listed as many commands as / did")
        XCTAssertTrue(narrowed.allSatisfy { $0.text.hasPrefix("/st") })
    }

    /// The catalog names the same commands, and every one is a command HARC runs, so the demo never offers one the phone then refuses.
    func testTheCatalogOffersOnlyCommandsHARCRuns() async {
        let catalog = await catalog()
        XCTAssertFalse(catalog.entries.isEmpty, "the demo's catalog is empty")
        for entry in catalog.entries {
            XCTAssertTrue(SlashCommandSupport.supports(entry), "\(entry.name) is in the demo catalog but HARC refuses it")
        }
        let listed = Set(await complete("/").items.map(\.text))
        XCTAssertEqual(listed, Set(catalog.entries.map(\.name)), "the list and the catalog disagree about which commands exist")
    }

    /// The control: text that is not a command gets no list, as on a real gateway.
    func testTextThatIsNotACommandGetsNoList() async {
        let items = await complete("hello").items
        XCTAssertTrue(items.isEmpty)
    }
}

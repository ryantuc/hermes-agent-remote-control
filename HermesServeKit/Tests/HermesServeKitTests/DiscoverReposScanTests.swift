import XCTest

@testable import HermesServeKit

/// FEAT-013 — `projects.discover_repos` `scan: true`.
///
/// Two things are being pinned, and the second matters more than the first.
/// One: the parameter reaches the wire under the name the backend reads
/// (`params.get("scan")`, `tui_gateway/methods_config.py:47`). Two: the default
/// call does **not** carry it. The scan is a synchronous disk walk inside the
/// RPC, so a default that quietly turned it on would put a host filesystem walk
/// behind every open of the folder picker.
final class DiscoverReposScanTests: XCTestCase {

    private static let repos: JSONValue = .object([
        "repos": .array([
            .object([
                "root": .string("/Users/you/code/hermes"),
                "label": .string("hermes"),
                "sessions": .number(4),
                "last_active": .number(1_755_767_100),
            ]),
        ]),
    ])

    func testTheDefaultCallSendsNoScanFlag() async throws {
        let (client, transport) = try await ScriptedGateway.connected(
            replies: ["projects.discover_repos": [Self.repos]]
        )
        let api = ProjectsAPI(client: client)

        let found = try await api.discoverRepos()
        XCTAssertEqual(found.map(\.label), ["hermes"])

        let params = await transport.sentParams("projects.discover_repos")
        XCTAssertNil(
            params?["scan"],
            "a picker open must not walk the host's disk"
        )
    }

    func testAnExplicitRefreshAsksTheBackendToScan() async throws {
        let (client, transport) = try await ScriptedGateway.connected(
            replies: ["projects.discover_repos": [Self.repos]]
        )
        let api = ProjectsAPI(client: client)

        let found = try await api.discoverRepos(scan: true)
        XCTAssertEqual(found.map(\.root), ["/Users/you/code/hermes"])

        let params = await transport.sentParams("projects.discover_repos")
        XCTAssertEqual(params?["scan"]?.coercedBool, true)
    }

    /// The scan is best-effort on the backend — a partial walk merges rather
    /// than replaces — so the client must read the answer the same way either
    /// way. Nothing about `scan: true` changes the decode.
    func testTheScanAnswerDecodesLikeAnyOther() async throws {
        let (client, _) = try await ScriptedGateway.connected(
            replies: ["projects.discover_repos": [.object([
                "repos": .array([
                    .object(["root": .string("/srv/never-opened"), "label": .string("never-opened")]),
                ]),
                "authoritative": .bool(false),
            ])]]
        )
        let api = ProjectsAPI(client: client)

        let found = try await api.discoverRepos(scan: true)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].label, "never-opened")
        XCTAssertEqual(found[0].sessions, 0, "a repo no session ever touched is the point")
    }
}

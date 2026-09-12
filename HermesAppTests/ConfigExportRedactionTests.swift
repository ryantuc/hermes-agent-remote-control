import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-085 — About → Export configuration shared the backend's file whole
/// under the sentence "Secrets are not part of the configuration".
///
/// The claim was about somebody else's document, made in this app, enforced
/// nowhere. `GET /api/config` filters `_`-prefixed keys and nothing else, and
/// `load_config()` expands `${VAR}` before the response is built — so a config
/// written with a template arrives here carrying the literal secret. The harm
/// is not exfiltration: it is a false assurance on the one control whose
/// purpose is to talk a person into pasting the result into a bug report.
///
/// The fixture below is a synthetic `config.yaml` covering the shapes a secret can hide in — provider slots, a `dashboard.basic_auth` block, MCP servers with `env` — and every value in it is invented.
final class ConfigExportRedactionTests: XCTestCase {

    private let mask = ConfigExportRedaction.placeholder

    private func fixture() -> JSONValue {
        .object([
            "model": .string("nous/hermes-4"),
            "timezone": .string("America/Chicago"),
            "providers": .object([
                "openai": .object([
                    "api_key": .string("sk-" + "INVENTED-VALUE-000001"),
                    "key_env": .string("OPENAI_API_KEY"),
                    "base_url": .string("https://api.example.invalid/v1"),
                    "enabled": .bool(true),
                ]),
                "anthropic": .object([
                    "api_key": .string(""),
                    "key_env": .string("ANTHROPIC_API_KEY"),
                ]),
            ]),
            "dashboard": .object([
                "basic_auth": .object([
                    "enabled": .bool(true),
                    "username": .string("you"),
                    "password": .string("INVENTED-PASSWORD-01"),
                    "password_hash": .string("$2b$12$inventedhashvalue"),
                    "secret": .string("INVENTED-SESSION-SECRET"),
                ]),
                "oauth": .object([
                    "client_id": .string("INVENTED-CLIENT-ID"),
                    "client_secret": .string("INVENTED-CLIENT-SECRET"),
                ]),
            ]),
            "mcp_servers": .object([
                "search": .object([
                    "command": .string("npx"),
                    "args": .array([.string("-y"), .string("@example/search")]),
                    "env": .object([
                        "SEARCH_TOKEN": .string("INVENTED-MCP-TOKEN-123"),
                        "PATH": .string("/usr/bin"),
                    ]),
                ]),
            ]),
            "terminal": .object([
                "cwd": .string("~/Developer/myproject"),
                "env_passthrough": .array([.string("HOME"), .string("PATH")]),
                "timeout": .number(120),
            ]),
            "code_execution": .object(["mode": .string("project")]),
            "agent": .object(["max_turns": .null, "client_id": .string("ios")]),
        ])
    }

    private func value(_ document: JSONValue, _ path: String) -> JSONValue? {
        ConfigDocument.value(at: path, in: document)
    }

    // MARK: The named keys

    func testAPlaintextProviderKeyIsRemovedAndItsNeighboursAreNot() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "providers.openai.api_key"), .string(mask))
        XCTAssertEqual(
            value(out, "providers.openai.key_env"), .string("OPENAI_API_KEY"),
            "a variable name is not a secret, and it is the useful half of a bug report"
        )
        XCTAssertEqual(value(out, "providers.openai.base_url"), .string("https://api.example.invalid/v1"))
        XCTAssertEqual(value(out, "providers.openai.enabled"), .bool(true))
    }

    /// A real config carries many empty provider slots, and masking them would claim secrets that are not there; "unset" is a fact a reader needs.
    func testAnEmptySlotStaysEmpty() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "providers.anthropic.api_key"), .string(""))
    }

    func testDashboardAuthGoesEntirely() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "dashboard.basic_auth.password"), .string(mask))
        XCTAssertEqual(value(out, "dashboard.basic_auth.password_hash"), .string(mask))
        XCTAssertEqual(value(out, "dashboard.basic_auth.secret"), .string(mask))
        XCTAssertEqual(value(out, "dashboard.basic_auth.username"), .string(mask))
    }

    /// One bit is not a credential, and a masked `enabled` would make the
    /// export unreadable as the document it came from.
    func testAStructuralBooleanSurvivesInsideACondemnedBlock() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "dashboard.basic_auth.enabled"), .bool(true))
    }

    /// A client id is half of an auth pair under `dashboard`/`oauth` and an
    /// ordinary identifier anywhere else. Masking it everywhere breaks the
    /// support workflow it exists for.
    func testClientIdIsScopedToWhereItIsHalfOfACredential() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "dashboard.oauth.client_id"), .string(mask))
        XCTAssertEqual(value(out, "dashboard.oauth.client_secret"), .string(mask))
        XCTAssertEqual(value(out, "agent.client_id"), .string("ios"))
    }

    // MARK: The subtree the key names cannot see

    /// An MCP server's `env` block is how that server is handed its keys, and
    /// the variable names inside it are arbitrary — so no name list can find
    /// them and the whole block goes, keys kept.
    func testEveryMCPEnvironmentValueGoesAndItsKeysStay() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "mcp_servers.search.env.SEARCH_TOKEN"), .string(mask))
        XCTAssertEqual(
            value(out, "mcp_servers.search.env.PATH"), .string(mask),
            "the block goes whole — deciding which variable is a secret is exactly what cannot be done"
        )
        XCTAssertEqual(value(out, "mcp_servers.search.command"), .string("npx"))
        XCTAssertEqual(
            value(out, "mcp_servers.search.args"),
            .array([.string("-y"), .string("@example/search")])
        )
    }

    /// `env_passthrough` is a list of variable *names*, not a map of values,
    /// and the rule is deliberately about objects named `env`.
    func testEnvPassthroughIsNotAnEnvironmentBlock() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(
            value(out, "terminal.env_passthrough"),
            .array([.string("HOME"), .string("PATH")])
        )
    }

    // MARK: Everything else is bit-for-bit

    func testOrdinaryConfigurationIsUntouched() {
        let out = ConfigExportRedaction.redactForShare(fixture()).document
        XCTAssertEqual(value(out, "model"), .string("nous/hermes-4"))
        XCTAssertEqual(value(out, "timezone"), .string("America/Chicago"))
        XCTAssertEqual(value(out, "terminal.cwd"), .string("~/Developer/myproject"))
        XCTAssertEqual(value(out, "terminal.timeout"), .number(120))
        XCTAssertEqual(value(out, "code_execution.mode"), .string("project"))
        XCTAssertEqual(value(out, "agent.max_turns"), .null)
    }

    func testADocumentWithNothingSecretComesBackIdentical() {
        let plain: JSONValue = .object([
            "model": .string("nous/hermes-4"),
            "terminal": .object(["cwd": .string("~"), "timeout": .number(60)]),
        ])
        let result = ConfigExportRedaction.redactForShare(plain)
        XCTAssertEqual(result.document, plain)
        XCTAssertFalse(result.didRedactAnything)
        XCTAssertFalse(result.usedFallbackLiteralPass)
    }

    // MARK: The expanded-literal residual pass

    /// `load_config()` expands `${VAR}` before serving, so one secret can
    /// appear both under `api_key` — where a name list finds it — and verbatim
    /// under a custom key, where nothing does. Matching the literal is all that
    /// is left once expansion has erased the provenance.
    func testARepeatedSecretIsCaughtUnderAKeyNoListKnows() {
        let document: JSONValue = .object([
            "providers": .object([
                "openai": .object(["api_key": .string("sk-" + "INVENTED-VALUE-000001")]),
            ]),
            "headers": .object(["X-Custom": .string("sk-" + "INVENTED-VALUE-000001")]),
        ])
        let result = ConfigExportRedaction.redactForShare(document)
        XCTAssertEqual(value(result.document, "headers.X-Custom"), .string(mask))
        XCTAssertTrue(result.usedFallbackLiteralPass, "the copy has to be able to say this happened")
    }

    /// It cannot be aggressive: a short repeated string in a config file is far
    /// likelier to be a shared word than a leaked key, and masking `project`
    /// everywhere would make the export useless.
    func testAShortRepeatedValueIsNotTreatedAsASecret() {
        let document: JSONValue = .object([
            "dashboard": .object(["basic_auth": .object(["password": .string("hunter2")])]),
            "code_execution": .object(["mode": .string("hunter2")]),
        ])
        let result = ConfigExportRedaction.redactForShare(document)
        XCTAssertEqual(value(result.document, "dashboard.basic_auth.password"), .string(mask))
        XCTAssertEqual(value(result.document, "code_execution.mode"), .string("hunter2"))
        XCTAssertFalse(result.usedFallbackLiteralPass)
    }

    // MARK: The counts the copy branches on

    func testTheResultReportsWhatItDid() {
        let result = ConfigExportRedaction.redactForShare(fixture())
        XCTAssertTrue(result.didRedactAnything)
        XCTAssertGreaterThan(result.redactedKeyCount, 0)
        XCTAssertGreaterThan(result.redactedValueCount, 0)
    }

    /// The shape is preserved so a backup consumer still recognises the file:
    /// keys are masked, never deleted.
    func testNoKeyIsEverDropped() {
        func keys(_ value: JSONValue, into out: inout Set<String>) {
            switch value {
            case .object(let fields):
                for (key, child) in fields {
                    out.insert(key)
                    keys(child, into: &out)
                }
            case .array(let items):
                for item in items { keys(item, into: &out) }
            default:
                break
            }
        }
        var before: Set<String> = []
        var after: Set<String> = []
        keys(fixture(), into: &before)
        keys(ConfigExportRedaction.redactForShare(fixture()).document, into: &after)
        XCTAssertEqual(before, after)
    }
}

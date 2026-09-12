import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// BUG-078 — the two config keys the backend refuses to read apart.
///
/// `PUT /api/config` pops `model_context_length` off the payload
/// unconditionally and applies it only inside the branch that a non-empty
/// `model` in the *same payload* opens. The desktop always sends both; the
/// phone is the only minimal-partial writer on this endpoint, so it was the
/// only client that could lose. Writing Context window alone was discarded and
/// reported as success; writing Default model alone deleted an override set
/// from desktop or CLI that the iOS UI never showed.
///
/// These pin the emitted PUT body, which is where the defect lives. The
/// document fixtures are nested exactly as `GET /api/config` serves them — both
/// keys are top level in the normalized web shape.
final class SettingsModelWritePairingTests: XCTestCase {

    /// Defect A. The user types a context length; the body must carry the model
    /// too, or the backend's branch never opens and the number is dropped while
    /// the response says `{"ok": true}`.
    @MainActor
    func testWritingTheContextLengthAlsoSendsTheModel() throws {
        let document = ConfigDocument.setting(
            .object(["model": .string("openrouter/anthropic/claude-opus-4")]),
            path: "model_context_length",
            to: .number(200_000)
        )

        let body = try XCTUnwrap(
            SettingsStore.modelWritePartial(path: "model_context_length", in: document),
            "a context-length write must not go out as a lone key"
        )
        XCTAssertEqual(body["model"]?.coercedString, "openrouter/anthropic/claude-opus-4")
        XCTAssertEqual(body["model_context_length"]?.coercedInt, 200_000)
        XCTAssertEqual(body.objectValue?.count, 2, "nothing else rides along")
    }

    /// Defect B, and the destructive half. Changing the model must carry the
    /// existing override forward, because a payload without it makes the
    /// backend run `disk_model.pop("context_length", None)`.
    @MainActor
    func testWritingTheModelCarriesAnExistingContextOverrideForward() throws {
        let document = ConfigDocument.setting(
            .object([
                "model": .string("openrouter/old/slug"),
                "model_context_length": .number(128_000),
            ]),
            path: "model",
            to: .string("openrouter/new/slug")
        )

        let body = try XCTUnwrap(SettingsStore.modelWritePartial(path: "model", in: document))
        XCTAssertEqual(body["model"]?.coercedString, "openrouter/new/slug", "the edit is what is written")
        XCTAssertEqual(
            body["model_context_length"]?.coercedInt, 128_000,
            "the override the user set elsewhere must survive a model edit"
        )
    }

    /// Absence is how an override is unset. A document with no context key must
    /// not gain a manufactured `0`, which the backend reads as "delete it".
    @MainActor
    func testAModelWriteWithNoOverrideSendsOnlyTheModel() throws {
        let document: JSONValue = .object(["model": .string("openrouter/new/slug")])

        let body = try XCTUnwrap(SettingsStore.modelWritePartial(path: "model", in: document))
        XCTAssertEqual(body["model"]?.coercedString, "openrouter/new/slug")
        XCTAssertNil(body["model_context_length"], "a fabricated 0 would delete an override, not preserve one")
        XCTAssertEqual(body.objectValue?.count, 1)
    }

    /// With no model in the document the backend's branch cannot open whatever
    /// we send, so the pairing declines and the caller falls back to the
    /// ordinary minimal partial rather than inventing a model slug.
    @MainActor
    func testThePairingDeclinesWhenTheDocumentHasNoModel() {
        XCTAssertNil(SettingsStore.modelWritePartial(
            path: "model_context_length",
            in: .object(["model_context_length": .number(200_000)])
        ))
        XCTAssertNil(SettingsStore.modelWritePartial(
            path: "model",
            in: .object(["model": .string("")])
        ))
    }

    /// The pairing is scoped to those two keys and nothing else. Every other
    /// row keeps the minimal-partial contract, which is correct for a
    /// deep-merging endpoint and is what the rest of the settings tree relies
    /// on.
    @MainActor
    func testEveryOtherPathStillWritesAMinimalPartial() {
        let document: JSONValue = .object([
            "model": .string("openrouter/new/slug"),
            "model_context_length": .number(128_000),
            "approvals": .object(["timeout": .number(60)]),
        ])

        XCTAssertNil(SettingsStore.modelWritePartial(path: "approvals.timeout", in: document))
        XCTAssertNil(SettingsStore.modelWritePartial(path: "agent.reasoning_effort", in: document))

        XCTAssertEqual(
            ConfigDocument.partial(path: "approvals.timeout", value: .number(90)),
            .object(["approvals": .object(["timeout": .number(90)])])
        )
    }
}

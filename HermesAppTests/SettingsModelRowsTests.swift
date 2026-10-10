import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// The model rows in Settings: which rows open the catalogue picker, which opens the chain editor, what each shows, and where a pick is written.
///
/// The defect: the Default model row only took a typed slug, and the Fallback models row did nothing at all.
final class SettingsModelRowsTests: XCTestCase {

    private func row(_ key: String, in screen: SettingsScreenDescriptor) throws -> SettingRowDescriptor {
        try XCTUnwrap(screen.sections.flatMap(\.rows).first { $0.key == key }, "no row for \(key)")
    }

    // MARK: The kinds

    func testTheDefaultModelRowOpensThePickerForTheMainModel() throws {
        let model = try row("model", in: SettingsCatalog.modelReasoning)
        XCTAssertEqual(model.kind, .model(.mainDefault))
        XCTAssertFalse(model.advanced)
        XCTAssertEqual(model.description, "Model new chats start with. The pill in a conversation changes that conversation only.")
    }

    func testTheFallbackRowIsAnEditorNotADisplay() throws {
        let fallback = try row("fallback_providers", in: SettingsCatalog.modelReasoning)
        XCTAssertEqual(fallback.kind, .fallbackChain)
        XCTAssertFalse(fallback.advanced)
        XCTAssertEqual(fallback.description, "Tried in order if the main model fails.")
    }

    func testTheSubagentModelRowWritesItsProviderBesideIt() throws {
        let delegation = try row("delegation.model", in: SettingsCatalog.advanced)
        XCTAssertEqual(delegation.kind, .model(.pair(providerKey: "delegation.provider")))
    }

    func testTheHelperModelRowsAreAuxiliarySlotsBehindTheAdvancedGate() throws {
        let screen = SettingsCatalog.modelReasoning
        XCTAssertEqual(try row("auxiliary.vision.model", in: screen).kind, .model(.auxiliary(task: "vision")))
        XCTAssertEqual(try row("auxiliary.compression.model", in: screen).kind, .model(.auxiliary(task: "compression")))
        XCTAssertEqual(try row("auxiliary.title_generation.model", in: screen).kind, .model(.auxiliary(task: "title_generation")))
        for key in ["auxiliary.vision.model", "auxiliary.compression.model", "auxiliary.title_generation.model"] {
            XCTAssertTrue(try row(key, in: screen).advanced, "\(key) stays out of the way until Advanced is on")
        }
    }

    func testNoModelRowIsAFreeTextFieldAnyMore() {
        for screen in SettingsScreenID.allCases.map(SettingsCatalog.screen) {
            for row in screen.sections.flatMap(\.rows) where row.key.hasSuffix("model") {
                if case .text = row.kind { XCTFail("\(row.key) still takes a typed slug only") }
            }
        }
    }

    // MARK: The provider key beside a model key

    func testEachTargetNamesItsProviderKey() {
        XCTAssertNil(ModelSettingTarget.mainDefault.providerKey(forModelKey: "model"))
        XCTAssertEqual(
            ModelSettingTarget.pair(providerKey: "delegation.provider").providerKey(forModelKey: "delegation.model"),
            "delegation.provider"
        )
        XCTAssertEqual(
            ModelSettingTarget.auxiliary(task: "vision").providerKey(forModelKey: "auxiliary.vision.model"),
            "auxiliary.vision.provider"
        )
        XCTAssertFalse(ModelSettingTarget.mainDefault.canInherit, "the main model has nothing to inherit from")
        XCTAssertTrue(ModelSettingTarget.auxiliary(task: "vision").canInherit)
    }

    // MARK: What the rows show

    @MainActor
    func testTheRowsShowTheSlugOrTheInheritWording() {
        XCTAssertEqual(
            SettingsStore.modelDisplay(ModelPair(provider: "", model: "anthropic/claude-sonnet-4.6"), target: .mainDefault),
            "anthropic/claude-sonnet-4.6"
        )
        XCTAssertEqual(SettingsStore.modelDisplay(ModelPair(provider: "", model: ""), target: .mainDefault), "None")
        XCTAssertEqual(
            SettingsStore.modelDisplay(ModelPair(provider: "openrouter", model: "google/gemini-3-flash-preview"), target: .auxiliary(task: "vision")),
            "openrouter/google/gemini-3-flash-preview"
        )
        XCTAssertEqual(
            SettingsStore.modelDisplay(ModelPair(providerValue: .string("auto"), modelValue: .string("")), target: .auxiliary(task: "vision")),
            "Same as main model"
        )
        XCTAssertEqual(
            SettingsStore.modelDisplay(ModelPair(provider: "", model: ""), target: .pair(providerKey: "delegation.provider")),
            "Same as main model"
        )
        XCTAssertEqual(SettingsStore.chainDisplay(count: 0), "None")
        XCTAssertEqual(SettingsStore.chainDisplay(count: 1), "1 model")
        XCTAssertEqual(SettingsStore.chainDisplay(count: 3), "3 models")
    }

    // MARK: Where a pick goes

    func testACataloguePickForTheMainModelGoesThroughTheAssignmentRoute() {
        let pair = ModelPair(provider: "anthropic", model: "claude-opus-4.6")
        XCTAssertEqual(
            ModelSettingTarget.mainDefault.write(for: .catalogue(pair), modelKey: "model"),
            .assign(.main, pair)
        )
    }

    func testATypedSlugForTheMainModelGoesThroughTheFlatKey() {
        XCTAssertEqual(
            ModelSettingTarget.mainDefault.write(for: .typed("openrouter/some/new-model"), modelKey: "model"),
            .flatModel("openrouter/some/new-model")
        )
        if case .refuse = ModelSettingTarget.mainDefault.write(for: .inherit, modelKey: "model") {} else {
            XCTFail("the main model cannot be cleared")
        }
    }

    func testAnAuxiliarySlotGoesThroughTheAssignmentRouteAndClearsWithAuto() {
        let target = ModelSettingTarget.auxiliary(task: "compression")
        let pair = ModelPair(provider: "openrouter", model: "google/gemini-3-flash-preview")
        XCTAssertEqual(
            target.write(for: .catalogue(pair), modelKey: "auxiliary.compression.model"),
            .assign(.auxiliary(task: "compression"), pair)
        )
        XCTAssertEqual(
            target.write(for: .inherit, modelKey: "auxiliary.compression.model"),
            .assign(.auxiliary(task: "compression"), ModelPair(provider: "auto", model: ""))
        )
        XCTAssertEqual(
            target.write(for: .typed("openrouter/x/y"), modelKey: "auxiliary.compression.model"),
            .assign(.auxiliary(task: "compression"), ModelPair(provider: "openrouter", model: "x/y"))
        )
        XCTAssertEqual(
            target.write(for: .typed("bare-slug"), modelKey: "auxiliary.compression.model"),
            .refuse(ModelSettingTarget.needsProviderMessage),
            "a slot write needs a provider the backend can call"
        )
    }

    @MainActor
    func testTheSubagentPairIsWrittenAsOnePartialAndClearedTogether() {
        let target = ModelSettingTarget.pair(providerKey: "delegation.provider")
        let pair = ModelPair(provider: "openrouter", model: "google/gemini-3-flash-preview")
        XCTAssertEqual(
            target.write(for: .catalogue(pair), modelKey: "delegation.model"),
            .pair(providerKey: "delegation.provider", modelKey: "delegation.model", pair)
        )
        XCTAssertEqual(
            target.write(for: .inherit, modelKey: "delegation.model"),
            .pair(providerKey: "delegation.provider", modelKey: "delegation.model", ModelPair(provider: "", model: ""))
        )
        XCTAssertEqual(
            SettingsStore.pairWritePartial(providerKey: "delegation.provider", modelKey: "delegation.model", pair: pair),
            .object(["delegation": .object([
                "provider": .string("openrouter"),
                "model": .string("google/gemini-3-flash-preview"),
            ])])
        )
    }

    // MARK: Reading the pair back out of a document

    @MainActor
    func testThePairIsReadOffTheDocumentsSiblingKeys() async {
        let harness = await AppHarness.make()
        harness.app.settings.injectDocumentForTesting(.object([
            "model": .string("anthropic/claude-sonnet-4.6"),
            "delegation": .object(["provider": .string("openrouter"), "model": .string("google/gemini-3-flash-preview")]),
            "auxiliary": .object(["vision": .object(["provider": .string("auto"), "model": .string("")])]),
            "fallback_providers": .array([
                .object(["provider": .string("nous"), "model": .string("hermes-4-405b")]),
            ]),
        ]))
        let store = harness.app.settings!

        XCTAssertEqual(
            store.modelPair(modelKey: "model", target: .mainDefault),
            ModelPair(provider: "", model: "anthropic/claude-sonnet-4.6")
        )
        XCTAssertEqual(
            store.modelPair(modelKey: "delegation.model", target: .pair(providerKey: "delegation.provider")),
            ModelPair(provider: "openrouter", model: "google/gemini-3-flash-preview")
        )
        XCTAssertTrue(store.modelPair(modelKey: "auxiliary.vision.model", target: .auxiliary(task: "vision")).isEmpty)
        XCTAssertEqual(store.fallbackChain().map(\.pair), [ModelPair(provider: "nous", model: "hermes-4-405b")])
    }
}

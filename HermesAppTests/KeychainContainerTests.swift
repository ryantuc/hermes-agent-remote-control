import Foundation
import HermesServeKit
import XCTest

@testable import HermesMobile

/// The same durability assertion `KeychainPersistenceTests` makes, run from
/// inside the app.
///
/// It is not redundant. `HermesServeKitTests` has no `TEST_HOST`, so it runs in
/// a bare `xctest` process with no app sandbox, and
/// `.applicationSupportDirectory` resolves there to the simulator's device-wide
/// `data/Library/Application Support`. The app resolves the same call to its
/// own container. Both persist, but only one of them is the path that shipped,
/// and this target is hosted by `HermesMobile.app` — so this is that path.
///
/// Simulator-only, like its kit sibling: on device the Keychain is available
/// and the fallback these tests exercise is not compiled in.
#if targetEnvironment(simulator)
final class KeychainContainerTests: XCTestCase {
    /// A password stored by the app is still readable after the process that
    /// stored it is gone.
    func testSecretStoredInsideTheAppSurvivesARelaunch() throws {
        let service = "com.hermes.mobile.tests.\(UUID().uuidString)"
        let account = "\(UUID().uuidString).password"
        let store = KeychainStore(service: service)
        defer { try? store.delete(account: account) }

        try store.setString("correct-horse-battery-staple", for: account)
        XCTAssertEqual(try store.string(for: account), "correct-horse-battery-staple")

        KeychainStore.simulateProcessRelaunch()

        XCTAssertEqual(
            try KeychainStore(service: service).string(for: account),
            "correct-horse-battery-staple",
            "a secret stored by the app must survive the app"
        )
    }

    /// Wherever the secret went, it went somewhere the app owns and nobody else
    /// on the device can read. On an unsigned build that is the fallback file in
    /// the container; on a signed one the Keychain takes the write and this
    /// finds nothing, which is the better outcome and also fine.
    func testTheFallbackFileIfUsedIsContainerScopedAndPrivate() throws {
        let store = KeychainStore(service: "com.hermes.mobile.tests.\(UUID().uuidString)")
        let account = "\(UUID().uuidString).password"
        defer { try? store.delete(account: account) }
        try store.setString("value", for: account)

        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return XCTFail("no Application Support directory") }
        let file = support.appendingPathComponent("hermes-simulator-secrets.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return  // Keychain took the write; nothing on disk to vet.
        }

        XCTAssertTrue(
            file.path.contains("/Containers/Data/Application/"),
            "the fallback must live in the app's own container, not device-wide: \(file.path)"
        )
        let permissions = try FileManager.default
            .attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "the fallback file must not be group- or world-readable")
    }
}
#endif

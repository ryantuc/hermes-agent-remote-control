import XCTest

@testable import HermesServeKit

/// A credential stored at sign-in has to outlive the process that stored it.
///
/// The failure this guards against does not present as a storage failure. The
/// profile row survives, and so does the login cookie, so REST keeps
/// authenticating and the Home resume strip still lists real sessions — only
/// the WebSocket path notices, because `webSocketURL(authRequired:)` checks
/// `hasSecret(.password)` and throws before any network I/O. What the user sees
/// is "Sign in again" on a backend they signed into yesterday.
///
/// Simulator-only: on device the Keychain is always available, and these tests
/// exist to hold the simulator's stand-in store to the same promise.
#if targetEnvironment(simulator)
final class KeychainPersistenceTests: XCTestCase {
    private let configuration = BackendConfiguration(
        baseURL: URL(string: "https://backend.example")!,
        authMode: .password,
        providerName: "basic",
        username: "you"
    )

    /// A fresh service name per run, so that a signed build — where these land
    /// in the real Keychain rather than the fallback — cannot collide with a
    /// previous run, with the app, or with a sibling test.
    private func makeService() -> String {
        "com.hermes.mobile.tests.\(UUID().uuidString)"
    }

    /// The regression test. Store a password under a profile id, lose the
    /// process, and build a fresh client against the same id: the password is
    /// still there.
    func testStoredPasswordSurvivesAProcessRelaunch() async throws {
        let service = makeService()
        let profileID = UUID().uuidString
        defer {
            AuthenticationClient.clearSecrets(
                profileID: profileID,
                keychain: KeychainStore(service: service)
            )
        }

        let signIn = AuthenticationClient(
            configuration: configuration,
            profileID: profileID,
            keychain: KeychainStore(service: service)
        )
        try await signIn.setSecret("correct-horse-battery-staple", kind: .password)
        let visibleToItsWriter = await signIn.hasSecret(.password)
        XCTAssertTrue(visibleToItsWriter, "the client that wrote the secret must see it")

        // The process that signed in is gone. Anything it held only in memory
        // goes with it; anything the store promised to persist does not.
        KeychainStore.simulateProcessRelaunch()

        let coldLaunch = AuthenticationClient(
            configuration: configuration,
            profileID: profileID,
            keychain: KeychainStore(service: service)
        )
        let survived = await coldLaunch.hasSecret(.password)
        XCTAssertTrue(
            survived,
            "a password stored at sign-in must still be readable on the next cold launch"
        )
    }

    /// Every `SecretKind` uses the same storage path, so a regression that
    /// drops one drops all four. Kept separate from the password case because
    /// only `.password` and `.bearerToken` gate `webSocketURL`.
    func testEverySecretKindSurvivesAProcessRelaunch() async throws {
        let service = makeService()
        let profileID = UUID().uuidString
        defer {
            AuthenticationClient.clearSecrets(
                profileID: profileID,
                keychain: KeychainStore(service: service)
            )
        }

        let signIn = AuthenticationClient(
            configuration: configuration,
            profileID: profileID,
            keychain: KeychainStore(service: service)
        )
        for kind in AuthenticationClient.SecretKind.allCases {
            try await signIn.setSecret("value-for-\(kind.rawValue)", kind: kind)
        }

        KeychainStore.simulateProcessRelaunch()

        let coldLaunch = AuthenticationClient(
            configuration: configuration,
            profileID: profileID,
            keychain: KeychainStore(service: service)
        )
        for kind in AuthenticationClient.SecretKind.allCases {
            let survived = await coldLaunch.hasSecret(kind)
            XCTAssertTrue(survived, "\(kind.rawValue) must survive a cold launch")
        }
    }

    /// Two profiles pointed at the same backend keep separate slots, and a
    /// relaunch does not merge or cross-wire them.
    func testSecretsStayNamespacedPerProfileAcrossARelaunch() async throws {
        let service = makeService()
        let mine = UUID().uuidString
        let theirs = UUID().uuidString
        defer {
            AuthenticationClient.clearSecrets(profileID: mine, keychain: KeychainStore(service: service))
            AuthenticationClient.clearSecrets(profileID: theirs, keychain: KeychainStore(service: service))
        }

        let signIn = AuthenticationClient(
            configuration: configuration,
            profileID: mine,
            keychain: KeychainStore(service: service)
        )
        try await signIn.setSecret("only-mine", kind: .password)

        KeychainStore.simulateProcessRelaunch()

        let other = AuthenticationClient(
            configuration: configuration,
            profileID: theirs,
            keychain: KeychainStore(service: service)
        )
        let leaked = await other.hasSecret(.password)
        XCTAssertFalse(leaked, "a different profile id must not see this profile's password")
    }

    /// Pins the throw site the live failure came through: with `authRequired`
    /// and no stored credential, the password path refuses before it opens a
    /// socket, and the message it throws is the one the banner renders.
    func testWebSocketURLRefusesWithoutAStoredPassword() async throws {
        let service = makeService()
        let profileID = UUID().uuidString
        let auth = AuthenticationClient(
            configuration: configuration,
            profileID: profileID,
            keychain: KeychainStore(service: service)
        )

        do {
            _ = try await auth.webSocketURL(authRequired: true)
            XCTFail("expected a missingCredential throw, got a URL")
        } catch let error as HermesError {
            guard case .missingCredential(let message) = error else {
                return XCTFail("expected .missingCredential, got \(error)")
            }
            XCTAssertEqual(message, "This backend requires sign-in. Add credentials in Settings.")
        }
    }
}
#endif

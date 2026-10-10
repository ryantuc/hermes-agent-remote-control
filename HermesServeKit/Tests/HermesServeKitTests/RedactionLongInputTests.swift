import Foundation
import XCTest

@testable import HermesServeKit

/// BUG-154 — `Redaction.text` must finish a long input in time proportional to its length, and must still mask a secret that sits past any point a cap would have cut.
///
/// The two credential-assignment patterns open with `[A-Za-z0-9_]*` so that `SOME_API_KEY=` matches, and nothing pinned that prefix to the start of a run of word characters, so the regex engine retried it from every position inside a run and rescanned the rest of the run each time. On the build Mac a 20,000-character run cost 145 to 356 seconds per call, which is where every native kit run spent about 95 % of its wall time (`LiveActivityDerivationTests`, two cases), and a 5,024-character run cost about 10 seconds in the app suite.
///
/// The deadline sits two orders of magnitude above the linear cost and more than one below the defect, so machine load cannot flake it either way. The work runs off the test thread so a regression fails at the deadline instead of holding the suite for minutes.
final class RedactionLongInputTests: XCTestCase {
    private static let deadline: TimeInterval = 10
    private static let canary = "S3CRETVALUE0123456789"

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Runs `work` on a background queue and stops waiting at the deadline. A semaphore rather than an expectation, because a regressed call keeps running after the test has moved on and must not touch XCTest state when it finally returns.
    private func withinDeadline(_ label: String, _ work: @escaping @Sendable () -> String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(work())
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.deadline) == .success else {
            XCTFail("\(label) did not finish within \(Self.deadline) s", file: file, line: line)
            return nil
        }
        print("BUG-154 \(label): \(String(format: "%.3f", Date().timeIntervalSince(started))) s")
        return box.get()
    }

    /// The exact input of the two stalled `LiveActivityDerivationTests` cases.
    func testATwentyThousandCharacterRunOfWordCharactersFinishes() {
        let input = String(repeating: "x", count: 20_000)
        let output = withinDeadline("20,000 x") { Redaction.text(input) }
        XCTAssertEqual(output, input, "nothing in a run of x is a secret")
    }

    /// The stack the native process sample caught: `ApprovalRequestEvent.init` redacts the whole command before anything caps it.
    func testTheApprovalEventPathTheSampleCaughtFinishes() {
        let command = String(repeating: "x", count: 20_000)
        let output = withinDeadline("approval event") {
            ApprovalRequestEvent(sessionID: "s1", payload: .object(["command": .string(command)])).command
        }
        XCTAssertEqual(output, command)
    }

    /// A hex dump is the realistic shape: a long hash or key fingerprint in tool output is one unbroken run of word characters.
    func testALongHexRunFinishes() {
        let input = String(repeating: "0123456789abcdef", count: 1_250)
        let output = withinDeadline("20,000 hex") { Redaction.text(input) }
        XCTAssertEqual(output, input)
    }

    /// Completeness: the key name is the tail of a 20,000-character identifier, so a scrubber that capped or skipped long runs would let the value through.
    func testAKeyThatEndsALongIdentifierIsStillMasked() {
        let input = String(repeating: "x", count: 20_000) + "_API_KEY=" + Self.canary
        guard let output = withinDeadline("long identifier key", { Redaction.text(input) }) else { return }
        XCTAssertFalse(output.contains(Self.canary), "the value after a 20,000-character key name leaked")
        XCTAssertTrue(output.hasSuffix("_API_KEY=" + Redaction.mask), "shape: \(output.suffix(40))")
        XCTAssertTrue(output.hasPrefix(String(repeating: "x", count: 20_000)), "the key name itself is not a secret")
    }

    /// Completeness: a secret that sits after 20,000 characters of harmless output is masked, which is what rules out truncating before inspecting.
    func testASecretAfterALongRunIsStillMasked() {
        let input = String(repeating: "x", count: 20_000) + " password=" + Self.canary + " and OPENAI_API_KEY=sk-proj-" + "abcdefghijklmnopqrstuvwxyz0123456789"
        guard let output = withinDeadline("secret after run", { Redaction.text(input) }) else { return }
        XCTAssertFalse(output.contains(Self.canary), "a password after 20,000 characters leaked")
        XCTAssertFalse(output.contains("abcdefghijklmnopqrstuvwxyz0123456789"), "a provider key after 20,000 characters leaked")
    }
}

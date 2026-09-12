import UIKit
import XCTest

@testable import HermesMobile

/// The mode control wants a bot glyph, and whether the SF Symbols catalog on this toolchain has one is a question about the toolchain. This resolves the candidates against the real catalog and prints what it finds, so the answer is a measurement rather than a memory of what SF Symbols shipped.
///
/// It asserts nothing about the candidates. A test that failed when Apple added a robot symbol would be a tripwire on someone else's release schedule; the finding belongs in `HomeModeControl`'s doc comment.
final class BotGlyphSymbolProbeTests: XCTestCase {

    func testWhichRobotCandidatesResolveInThisSFSymbolsCatalog() {
        let candidates = [
            "robot",
            "figure.robot",
            "brain",
            "brain.head.profile",
            "cpu",
            "bubble.left.and.bubble.right",
            "person.2",
            "face.smiling",
            "sparkles",
            "terminal",
        ]
        var resolved: [String] = []
        var missing: [String] = []
        for name in candidates {
            if UIImage(systemName: name) != nil { resolved.append(name) } else { missing.append(name) }
        }
        print("[bot-glyph] resolves: \(resolved.joined(separator: ", "))")
        print("[bot-glyph] missing: \(missing.joined(separator: ", "))")
        print("[bot-glyph] iOS \(UIDevice.current.systemVersion)")

        // The one thing we do depend on: the Sessions-side glyph.
        XCTAssertNotNil(UIImage(systemName: "terminal"),
                        "`terminal` is the glyph that returns to Sessions mode and it must exist")
    }
}

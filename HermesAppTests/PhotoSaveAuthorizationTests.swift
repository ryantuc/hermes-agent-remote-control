import Photos
import XCTest

@testable import HermesMobile

/// BUG-146 (`PhotoSave.swift` `save(_:)`) — the save requests `.addOnly` access and then accepted `.limited` as permission, but `.limited` exists only for `.readWrite`: the type's own documentation says add-only is authorised or denied with nothing between. Accepting a status the request cannot return is a branch nobody can reach; the decision is pinned here so the code says what its documentation says.
final class PhotoSaveAuthorizationTests: XCTestCase {

    func testOnlyAuthorizedLetsTheSaveGoAhead() {
        XCTAssertTrue(PhotoSave.canSave(with: .authorized))
    }

    func testLimitedIsNotAnAddOnlyAnswer() {
        XCTAssertFalse(PhotoSave.canSave(with: .limited),
                       "`.limited` belongs to read-write access; an add-only request is authorised or denied (BUG-146)")
    }

    func testEveryRefusalIsARefusal() {
        for status: PHAuthorizationStatus in [.denied, .restricted, .notDetermined] {
            XCTAssertFalse(PhotoSave.canSave(with: status), "\(status.rawValue) let the save go ahead")
        }
    }
}

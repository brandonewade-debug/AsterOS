import XCTest
@testable import AsterOS

final class PhotoBackupBackgroundTests: XCTestCase {
    func testDelayedTemporaryExpirationCannotCancelContinuedWork() {
        var state = PhotoBackupBackgroundOwnership()
        XCTAssertTrue(state.takeOver())
        XCTAssertFalse(state.expire(.temporary))
        XCTAssertEqual(state.owner, .continued)
        XCTAssertTrue(state.expire(.continued))
        XCTAssertFalse(state.expire(.continued))
    }
    func testTemporaryExpirationWinsBeforeTakeover() {
        var state = PhotoBackupBackgroundOwnership()
        XCTAssertTrue(state.expire(.temporary))
        XCTAssertFalse(state.takeOver())
        XCTAssertEqual(state.owner, .finished)
    }
    func testFinishedBackupIgnoresEveryLateCallback() {
        var state = PhotoBackupBackgroundOwnership()
        XCTAssertTrue(state.takeOver())
        state.finish()
        XCTAssertFalse(state.expire(.temporary))
        XCTAssertFalse(state.expire(.continued))
        XCTAssertFalse(state.takeOver())
    }
}

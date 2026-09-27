import XCTest
import Photos
@testable import AsterOS

final class PhotoDownloadRecoveryTests: XCTestCase {
    @MainActor func testTransientPhotoNetworkFailureRetriesAndSucceeds() async throws {
        var attempts = 0, retries: [Int] = []
        try await PhotoDownloadRecovery.run(attempt: {
            attempts += 1
            if attempts < 3 { throw NSError(domain: PHPhotosErrorDomain, code: 3169) }
        }, retry: { retries.append($0) }, wait: { _ in })
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(retries, [2, 3])
    }
    @MainActor func testExhaustionIsExplicitAndBounded() async {
        var attempts = 0
        do {
            try await PhotoDownloadRecovery.run(attempt: {
                attempts += 1
                throw NSError(domain: PHPhotosErrorDomain, code: 3169)
            }, retry: { _ in }, wait: { _ in })
            XCTFail("Must remain incomplete")
        } catch { XCTAssertTrue(error is PhotoDownloadUnavailable) }
        XCTAssertEqual(attempts, 3)
    }
    @MainActor func testOtherErrorsAreNotRetriedOrDeferred() async {
        var attempts = 0
        do {
            try await PhotoDownloadRecovery.run(attempt: {
                attempts += 1
                throw NSError(domain: PHPhotosErrorDomain, code: 3305)
            }, retry: { _ in XCTFail("No retry for full disk") }, wait: { _ in })
        } catch { XCTAssertEqual((error as NSError).code, 3305) }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(PhotoDownloadRecovery.isNetworkError(NSError(domain: "SMB", code: 3169)))
    }
    @MainActor func testCancellationDuringBackoffDoesNotRetry() async {
        var attempts = 0
        do {
            try await PhotoDownloadRecovery.run(attempt: {
                attempts += 1
                throw NSError(domain: PHPhotosErrorDomain, code: 3169)
            }, retry: { _ in }, wait: { _ in throw CancellationError() })
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }
}

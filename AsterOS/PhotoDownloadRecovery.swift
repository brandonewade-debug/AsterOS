import Foundation
import Photos

struct PhotoDownloadUnavailable: LocalizedError {
    var errorDescription: String? { "Photos could not download an original after three attempts. Check your internet connection and try again; completed items are saved." }
}
enum PhotoDownloadRecovery {
    static func isNetworkError(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == PHPhotosErrorDomain && value.code == PHPhotosError.Code.networkError.rawValue
    }
    @MainActor static func run(
        attempt: () async throws -> Void,
        retry: (Int) -> Void,
        wait: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        for number in 1...3 {
            try Task.checkCancellation()
            do { try await attempt(); try Task.checkCancellation(); return }
            catch {
                try Task.checkCancellation()
                guard isNetworkError(error) else { throw error }
                guard number < 3 else { throw PhotoDownloadUnavailable() }
                retry(number + 1)
                try await wait(number == 1 ? 2_000_000_000 : 5_000_000_000)
            }
        }
    }
}

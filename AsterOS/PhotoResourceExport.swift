import Foundation
import Photos

/// Cancellable export so pausing/expiration also stops an in-flight iCloud fetch.
final class PhotoResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var finished = false
    private let manager = PHAssetResourceManager.default()

    private init(file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw AppError.message("Could not prepare the photo for backup.")
        }
        handle = try FileHandle(forWritingTo: file)
    }
    static func write(_ resource: PHAssetResource, to file: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let operation = try PhotoResourceExport(file: file)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(resource, continuation: continuation, progress: progress)
            }
        } onCancel: { operation.cancel() }
    }
    private func start(_ resource: PHAssetResource, continuation: CheckedContinuation<Void, Error>, progress: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        self.continuation = continuation
        let cancelled = cancelled
        lock.unlock()
        if cancelled { complete(CancellationError()); return }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }
        let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { [self] data in
            lock.lock()
            guard !finished else { lock.unlock(); return }
            do { try handle.write(contentsOf: data); lock.unlock() }
            catch { lock.unlock(); complete(error) }
        }, completionHandler: { [self] error in complete(error) })
        lock.lock()
        requestID = id
        let shouldCancel = finished || self.cancelled
        lock.unlock()
        if shouldCancel { manager.cancelDataRequest(id) }
    }
    private func complete(_ error: Error?) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let requestID = requestID
        var outcome = error
        do { try handle.close() } catch { if outcome == nil { outcome = error } }
        lock.unlock()
        if let outcome {
            if let requestID { manager.cancelDataRequest(requestID) }
            continuation.resume(throwing: outcome)
        } else { continuation.resume() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        complete(CancellationError())
    }
    deinit { try? handle.close() }
}

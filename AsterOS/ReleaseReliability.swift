import Foundation

@MainActor enum TerminalIdentity {
    static func load(address: URL, defaults: UserDefaults = .standard) -> UUID {
        let key = "terminalSession-" + AppFoldersStore.addressKey(address)
        if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: key); return id
    }
}

enum BackupVerification {
    // Bounded reads work for large videos and allow cancellation between chunks.
    static func verify(size: UInt64, readLocal: (Int) throws -> Data,
                       readRemote: (UInt64, Int) async throws -> Data) async throws {
        var offset: UInt64 = 0
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(1_048_576, size - offset))
            let remote = try await readRemote(offset, count)
            guard !remote.isEmpty, remote.count <= count,
                  remote == (try readLocal(remote.count)) else {
                throw AppError.message("Upload verification failed. The file was not marked complete. Retry backup.")
            }
            offset += UInt64(remote.count)
        }
        guard try readLocal(1).isEmpty else { throw AppError.message("The source file changed during upload. Retry backup.") }
    }
}

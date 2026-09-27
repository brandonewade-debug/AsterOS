import Foundation
import CryptoKit

/// Local completion journal. Only append after the server receipt was verified.
/// A changed destination marker creates a different journal; ordinary resume never
/// rereads every remote receipt. Explicit verification rebuilds this journal.
final class PhotoBackupIndex {
    private(set) var identities: Set<String> = []
    let url: URL
    private let handle: FileHandle
    static func scope(server: String, host: String, account: String, share: String, folder: String, marker: String) -> String {
        let parts = [server, host.lowercased(), account, share, folder, marker]
        let bytes = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    init(scope: String, directory: URL? = nil, reset: Bool = false) throws {
        var directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhotoBackupIndex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        url = directory.appendingPathComponent(name + ".journal")
        if reset || !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let data = try Data(contentsOf: url)
        // Fixed-size, newline-terminated records make a torn final append harmless.
        var validLength = 0
        while validLength + 65 <= data.count {
            let record = data.subdata(in: validLength..<validLength + 64)
            guard data[validLength + 64] == 10,
                  record.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { break }
            identities.insert(String(decoding: record, as: UTF8.self))
            validLength += 65
        }
        handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: UInt64(validLength))
        try handle.seekToEnd()
    }
    func contains(_ identity: String) -> Bool { identities.contains(identity) }
    func record(_ identity: String) throws {
        guard !contains(identity) else { return }
        guard identity.utf8.count == 64, identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AppError.message("The photo completion record is invalid.")
        }
        try handle.write(contentsOf: Data((identity + "\n").utf8))
        try handle.synchronize()
        identities.insert(identity)
    }
    deinit { try? handle.close() }
}

import Foundation
import SMBClient

struct BackupStorageEntry { let name: String; let isDirectory: Bool; let size: UInt64 }
@MainActor final class BackupStorage {
    let smb: SMBClient?
    let seafile: SeafileClient?
    init(smb: SMBClient) { self.smb = smb; seafile = nil }
    init(seafile: SeafileClient) { smb = nil; self.seafile = seafile }
    func disconnect() { smb?.session.disconnect(); seafile?.disconnect() }
    func connectShare(_ name: String) async throws {
        if let smb { try await smb.connectShare(name) }
        else { try await seafile!.select(name, writing: true) }
    }
    func listDirectory(path: String) async throws -> [BackupStorageEntry] {
        if let smb { return try await smb.listDirectory(path: path).map { .init(name: $0.name, isDirectory: $0.isDirectory, size: $0.size) } }
        return try await seafile!.list(path).map { .init(name: $0.name, isDirectory: $0.isDirectory, size: $0.size ?? 0) }
    }
    func createDirectory(path: String) async throws {
        if let smb { try await smb.createDirectory(path: path) } else { try await seafile!.mkdir(path) }
    }
    func move(from: String, to: String) async throws {
        if let smb { try await smb.move(from: from, to: to) } else { try await seafile!.rename(from, to: to) }
    }
    func deleteFile(path: String) async throws {
        if let smb { try await smb.deleteFile(path: path) }
        // Failed Seafile staging uploads remain available for diagnosis. Never delete user files.
    }
    func fileReader(path: String) -> BackupStorageReader { .init(smb: smb?.fileReader(path: path), seafile: seafile, path: path) }
    func fileWriter(path: String) -> BackupStorageWriter { .init(smb: smb?.fileWriter(path: path), seafile: seafile, path: path) }
}
@MainActor final class BackupStorageReader {
    private let smb: FileReader?
    private let seafile: SeafileClient?
    private let path: String
    private var downloaded: URL?
    init(smb: FileReader?, seafile: SeafileClient?, path: String) { self.smb = smb; self.seafile = seafile; self.path = path }
    private func local() async throws -> URL {
        if let downloaded { return downloaded }
        let file = try await seafile!.download(path); downloaded = file; return file
    }
    var fileSize: UInt64 {
        get async throws {
            if let smb { return try await smb.fileSize }
            return UInt64(try await local().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
    func read(offset: UInt64, length: UInt32) async throws -> Data {
        if let smb { return try await smb.read(offset: offset, length: length) }
        let handle = try await FileHandle(forReadingFrom: local()); defer { try? handle.close() }
        try handle.seek(toOffset: offset); return try handle.read(upToCount: Int(length)) ?? Data()
    }
    func close() async throws {
        if let smb { try await smb.close() }
        if let downloaded { try? FileManager.default.removeItem(at: downloaded); self.downloaded = nil }
    }
}
@MainActor final class BackupStorageWriter {
    private let smb: FileWriter?
    private let seafile: SeafileClient?
    private let path: String
    init(smb: FileWriter?, seafile: SeafileClient?, path: String) { self.smb = smb; self.seafile = seafile; self.path = path }
    func upload(fileHandle: FileHandle, progress: @escaping @Sendable (Double) -> Void) async throws {
        if let smb { try await smb.upload(fileHandle: fileHandle, progressHandler: progress) }
        else { try await seafile!.upload(fileHandle, path: path, progress: progress) }
    }
    func close() async throws { if let smb { try await smb.close() } }
}

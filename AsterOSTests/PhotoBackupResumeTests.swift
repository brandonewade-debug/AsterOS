import XCTest
@testable import AsterOS

final class PhotoBackupResumeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testCompletedAssetsSurviveRestartAndChangedAssetsRemainPending() throws {
        let dir = try temporaryDirectory()
        let original = PhotoBackupPolicy.identifier("photo", modified: Date(timeIntervalSince1970: 1))
        let edited = PhotoBackupPolicy.identifier("photo", modified: Date(timeIntervalSince1970: 2))
        var index: PhotoBackupIndex? = try PhotoBackupIndex(scope: "server/share/folder", directory: dir)
        try index!.record(original)
        try index!.record(original) // Idempotent append.
        let url = index!.url
        index = nil
        let restored = try PhotoBackupIndex(scope: "server/share/folder", directory: dir)
        XCTAssertTrue(restored.contains(original))
        XCTAssertFalse(restored.contains(edited))
        XCTAssertEqual(try Data(contentsOf: url).count, 65)
    }
    func testDestinationAndAccountChangesNeverReuseCompletions() throws {
        let base = PhotoBackupIndex.scope(server: "s", host: "host", account: "u", share: "photos", folder: "Family", marker: "one")
        let alternatives = [
            PhotoBackupIndex.scope(server: "other", host: "host", account: "u", share: "photos", folder: "Family", marker: "one"),
            PhotoBackupIndex.scope(server: "s", host: "new-host", account: "u", share: "photos", folder: "Family", marker: "one"),
            PhotoBackupIndex.scope(server: "s", host: "host", account: "other", share: "photos", folder: "Family", marker: "one"),
            PhotoBackupIndex.scope(server: "s", host: "host", account: "u", share: "other", folder: "Family", marker: "one"),
            PhotoBackupIndex.scope(server: "s", host: "host", account: "u", share: "photos", folder: "Other", marker: "one"),
            PhotoBackupIndex.scope(server: "s", host: "host", account: "u", share: "photos", folder: "Family", marker: "replaced")
        ]
        for value in alternatives { XCTAssertNotEqual(base, value) }
        let dir = try temporaryDirectory(), identity = PhotoBackupPolicy.identifier("photo", modified: nil)
        let index = try PhotoBackupIndex(scope: base, directory: dir)
        try index.record(identity)
        for scope in alternatives { XCTAssertFalse(try PhotoBackupIndex(scope: scope, directory: dir).contains(identity)) }
    }
    func testTornAppendPreservesOnlyCommittedRecordsAndAllowsRecovery() throws {
        let dir = try temporaryDirectory()
        let first = PhotoBackupPolicy.identifier("first", modified: nil), second = PhotoBackupPolicy.identifier("second", modified: nil)
        var index: PhotoBackupIndex? = try PhotoBackupIndex(scope: "scope", directory: dir)
        try index!.record(first); let url = index!.url; index = nil
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd()
        try file.write(contentsOf: Data(second.prefix(32).utf8)); try file.close()
        index = try PhotoBackupIndex(scope: "scope", directory: dir)
        XCTAssertTrue(index!.contains(first)); XCTAssertFalse(index!.contains(second))
        try index!.record(second); index = nil
        let restored = try PhotoBackupIndex(scope: "scope", directory: dir)
        XCTAssertEqual(restored.identities, Set([first, second]))
    }
    func testExplicitVerificationClearsFastResumeIndex() throws {
        let dir = try temporaryDirectory(), identity = PhotoBackupPolicy.identifier("photo", modified: nil)
        var index: PhotoBackupIndex? = try PhotoBackupIndex(scope: "scope", directory: dir)
        try index!.record(identity); index = nil
        let rebuilt = try PhotoBackupIndex(scope: "scope", directory: dir, reset: true)
        XCTAssertFalse(rebuilt.contains(identity))
        try rebuilt.record(identity)
        XCTAssertTrue(rebuilt.contains(identity))
    }
    func testInvalidRecordCannotBeMarkedComplete() throws {
        let index = try PhotoBackupIndex(scope: "scope", directory: temporaryDirectory())
        XCTAssertThrowsError(try index.record("invalid"))
        XCTAssertTrue(index.identities.isEmpty)
    }
    func testTwentySevenThousandItemResumeUsesLocalMembership() throws {
        let dir = try temporaryDirectory()
        let ids = (0..<27_000).map { PhotoBackupPolicy.identifier("photo-\($0)", modified: nil) }
        var index: PhotoBackupIndex? = try PhotoBackupIndex(scope: "large", directory: dir)
        let url = index!.url; index = nil
        // Fixture represents receipts durably committed on a previous run.
        try Data((ids.joined(separator: "\n") + "\n").utf8).write(to: url)
        let began = Date()
        let restored = try PhotoBackupIndex(scope: "large", directory: dir)
        let pending = (ids + [PhotoBackupPolicy.identifier("new", modified: nil)]).filter { !restored.contains($0) }
        XCTAssertEqual(restored.identities.count, 27_000)
        XCTAssertEqual(pending.count, 1)
        print("LOCAL_RESUME_27000_SECONDS=\(Date().timeIntervalSince(began))")
    }
    @MainActor func testBackupOwnerSurvivesViewRecreationAndIsServerScoped() throws {
        let suite = "photo-owner-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fixture", address: URL(string: "https://fixture.invalid")!, connection: .custom)
        let other = ServerProfile(name: "Other", address: URL(string: "https://other.invalid")!, connection: .custom)
        defaults.set(try JSONEncoder().encode([profile, other]), forKey: "serverProfiles")
        let app = AppStore(defaults: defaults)
        let backup = app.photoBackup(for: profile)
        backup.share = "Photos"; backup.folder = "Family"
        XCTAssertTrue(backup === app.photoBackup(for: profile))
        app.select(other.id); app.select(profile.id)
        XCTAssertTrue(backup === app.photoBackup(for: profile))
        XCTAssertFalse(backup === app.photoBackup(for: other))
        XCTAssertEqual(app.photoBackup(for: profile).folder, "Family")
        app.showDemo(); app.exitDemo()
        XCTAssertTrue(backup === app.photoBackup(for: profile))
    }
}

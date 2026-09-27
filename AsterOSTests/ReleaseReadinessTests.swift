import XCTest
@testable import AsterOS

private final class StubServerAPI: ServerAPI {
    var failOverview = false
    var failContainers = false
    var actionCalls = 0
    var removalCalls = 0
    func overview() async throws -> Overview {
        if failOverview { throw AppError.message("Offline") }
        return .demo
    }
    func containers() async throws -> [Container] {
        if failContainers { throw AppError.message("Offline") }
        return [Container(id: "fixture", names: ["/fixture"], state: "RUNNING", status: "Up")]
    }
    func metrics() async throws -> Metrics { .demo }
    func perform(_ action: ContainerAction, id: String) async throws { actionCalls += 1 }
    func removeContainer(id: String) async throws { removalCalls += 1 }
}

final class ReleaseReadinessTests: XCTestCase {
    @MainActor func testFailedRefreshPreservesAppsAndClearsStaleMetrics() async throws {
        let suite = "release-tests-" + UUID().uuidString, api = StubServerAPI()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerProfile(name: "Fixture", address: URL(string: "https://fixture.invalid")!, connection: .custom)
        defaults.set(try JSONEncoder().encode([server]), forKey: "serverProfiles")
        let store = AppStore(defaults: defaults, client: { _ in api })
        await store.refresh()
        XCTAssertEqual(store.containers.count, 1)
        api.failContainers = true
        await store.refresh()
        XCTAssertEqual(store.containers.count, 1)
        XCTAssertNotNil(store.dockerError)
        api.failOverview = true
        await store.refresh()
        XCTAssertEqual(store.containers.count, 1)
        XCTAssertNil(store.metrics)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.loading)
        api.failOverview = false; api.failContainers = false
        await store.refresh()
        XCTAssertNil(store.error); XCTAssertNil(store.dockerError)
        XCTAssertNotNil(store.metrics)
    }
    @MainActor func testMutationRefreshFailureDoesNotRepeatActionOrLeaveLoadingStuck() async throws {
        let suite = "mutation-tests-" + UUID().uuidString, api = StubServerAPI()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerProfile(name: "Fixture", address: URL(string: "https://fixture.invalid")!, connection: .custom)
        defaults.set(try JSONEncoder().encode([server]), forKey: "serverProfiles")
        let store = AppStore(defaults: defaults, client: { _ in api })
        await store.refresh(); let container = try XCTUnwrap(store.containers.first)
        api.failContainers = true
        await store.perform(.stop, container: container)
        XCTAssertEqual(api.actionCalls, 1)
        XCTAssertTrue(store.dockerError?.contains("confirmed the action") == true)
        XCTAssertEqual(store.containers.count, 1)
        XCTAssertFalse(store.loading); XCTAssertFalse(store.operating)
        try await store.removeContainer(container, from: server.id)
        XCTAssertEqual(api.removalCalls, 1)
        XCTAssertTrue(store.containers.isEmpty)
        XCTAssertTrue(store.dockerError?.contains("removed") == true)
        XCTAssertFalse(store.loading); XCTAssertFalse(store.operating)
    }
    @MainActor func testTerminalIdentitySurvivesRestartAndIsServerScoped() {
        let suite = "terminal-identity-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = TerminalIdentity.load(address: URL(string: "https://SERVER.example:443")!, defaults: defaults)
        XCTAssertEqual(original, TerminalIdentity.load(address: URL(string: "https://server.example")!, defaults: UserDefaults(suiteName: suite)!))
        XCTAssertNotEqual(original, TerminalIdentity.load(address: URL(string: "https://other.example")!, defaults: defaults))
        XCTAssertNotEqual(original, TerminalIdentity.load(address: URL(string: "https://server.example:4443")!, defaults: defaults))
    }
    func testBackupVerificationAcceptsPartialReadsAcrossChunkBoundaries() async throws {
        let source = Data((0..<2_100_007).map { UInt8($0 % 251) })
        var localOffset = 0, calls = 0
        try await BackupVerification.verify(size: UInt64(source.count), readLocal: { count in
            defer { localOffset += min(count, source.count - localOffset) }
            return source.subdata(in: localOffset..<min(source.count, localOffset + count))
        }, readRemote: { offset, count in
            XCTAssertLessThanOrEqual(count, 1_048_576)
            calls += 1
            return source.subdata(in: Int(offset)..<min(source.count, Int(offset) + min(count, 400_000)))
        })
        XCTAssertEqual(localOffset, source.count)
        XCTAssertGreaterThan(calls, 2)
    }
    func testBackupVerificationRejectsSameSizeCorruptionEmptyAndOversizedReads() async {
        for response in [Data([2, 2, 3]), Data(), Data([1, 2, 3, 4])] {
            do {
                try await BackupVerification.verify(size: 3, readLocal: { _ in Data([1, 2, 3]) }, readRemote: { _, _ in response })
                XCTFail("Unverified uploads must never be committed")
            } catch { XCTAssertTrue(error.localizedDescription.contains("verification failed")) }
        }
    }
    @MainActor func testPreferencesRoundTripRestoresOrganizationAndKeepsRecoveryCopy() throws {
        let suite = "preferences-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerProfile(name: "Fixture", address: URL(string: "https://fixture.invalid")!, connection: .custom)
        let folders = AppFoldersStore(defaults: defaults); folders.load(serverID: server.id, address: server.address)
        _ = folders.create("Media", app: "container:plex")
        let key = "photoBackupAddress-" + AppFoldersStore.addressKey(server.address)
        defaults.set(["share": "Pictures", "folder": "Family/Backup"], forKey: key)
        defaults.set("daily", forKey: key + "-layout")
        defaults.set("America/Chicago", forKey: key + "-timeZone")
        defaults.set("secret", forKey: "arbitraryCredential")
        let archive = try PreferencesArchive.capture(server: server, defaults: defaults)
        let data = try JSONEncoder().encode(archive)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        _ = folders.create("New folder")
        let decoded = try PreferencesArchive.decode(data)
        try decoded.apply(to: server, defaults: defaults)
        folders.load(serverID: UUID(), address: server.address)
        XCTAssertEqual(folders.layout.folders.map(\.name), ["Media"])
        XCTAssertEqual(defaults.string(forKey: "arbitraryCredential"), "secret")
        let restored = try PreferencesArchive.capture(server: server, defaults: defaults)
        XCTAssertEqual(restored.photoFolder, "Family/Backup")
        XCTAssertEqual(restored.photoLayout, "daily")
        let recovery = try XCTUnwrap(defaults.data(forKey: "preferencesRecovery-" + AppFoldersStore.addressKey(server.address)))
        XCTAssertEqual(try PreferencesArchive.decode(recovery).folders.folders.count, 2)
        var invalid = decoded; invalid.photoFolder = "../outside"
        XCTAssertThrowsError(try invalid.apply(to: server, defaults: defaults))
        XCTAssertEqual(defaults.dictionary(forKey: key)?["folder"] as? String, "Family/Backup")
    }
    @MainActor func testPreferencesRejectUnknownVersionCredentialsInURLsAndDuplicateMembers() throws {
        var archive = PreferencesArchive(folders: AppFolderLayout(), apps: [], photoLayout: "monthly", terminalFont: 15)
        archive.version = 2; XCTAssertThrowsError(try archive.validate()); archive.version = 1
        archive.apps = [SavedApp(name: "Bad", url: URL(string: "https://user:secret@example.com")!)]
        XCTAssertThrowsError(try archive.validate()); archive.apps = []
        archive.folders.folders = [AppFolder(name: "A", members: ["container:plex"]), AppFolder(name: "B", members: ["container:plex"])]
        XCTAssertThrowsError(try archive.validate())
        XCTAssertThrowsError(try PreferencesArchive.decode(Data(count: 2_000_001)))
    }
    func testSupportReportUsesOnlyAllowedFields() {
        let report = SupportSnapshot(appVersion: "secret-host.example", systemVersion: "26.6.2", hasServer: true, privateConnected: true, overviewLoaded: false, appCount: -1, refreshFailed: true, dockerRefreshFailed: false).report
        XCTAssertFalse(report.contains("secret-host.example"))
        XCTAssertTrue(report.contains("App: unavailable"))
        XCTAssertTrue(report.contains("Loaded containers: 0"))
    }
    func testNativeInsightsDecodeOfficialAPIShapes() throws {
        let alerts = try JSONDecoder().decode(ServerAlertsData.self, from: Data(#"{"notifications":{"list":[{"id":"notification:1","title":"Warning","subject":"Storage","description":"Check storage","importance":"WARNING","timestamp":null}]}}"#.utf8))
        XCTAssertEqual(alerts.notifications.list.first?.importance, "WARNING")
        let logs = try JSONDecoder().decode(ContainerLogsData.self, from: Data(#"{"docker":{"logs":{"lines":[{"timestamp":"2026-09-27T00:00:00Z","message":"Ready"}]}}}"#.utf8))
        XCTAssertEqual(logs.docker.logs.lines.first?.message, "Ready")
    }
}

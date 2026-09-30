import XCTest
@testable import AsterOS

@MainActor final class SeafileTests: XCTestCase {
    func testFileLinksStayOnConfiguredOrigin() throws {
        let base = URL(string: "https://cloud.example.com")!
        XCTAssertEqual(try SeafilePolicy.transferURL("/seafhttp/files/token/file", base: base).host, base.host)
        for link in ["https://evil.example/file", "http://cloud.example.com/file", "https://cloud.example.com:8443/file", "https://user:pass@cloud.example.com/file", "//evil.example/file"] {
            XCTAssertThrowsError(try SeafilePolicy.transferURL(link, base: base))
        }
    }
    func testLibraryPermissionsAndEncryptedFlags() throws {
        for flag in ["true", "1", "null", "\"unknown\""] {
            let bytes = Data("{\"id\":\"11111111-2222-3333-4444-555555555555\",\"name\":\"Private\",\"permission\":\"rw\",\"encrypted\":\(flag)}".utf8)
            let item = try JSONDecoder().decode(SeafileLibrary.self, from: bytes)
            XCTAssertTrue(item.encrypted); XCTAssertFalse(item.writable)
        }
        let bytes = Data("{\"id\":\"11111111-2222-3333-4444-555555555555\",\"name\":\"Shared\",\"permission\":\"r\",\"encrypted\":false}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(SeafileLibrary.self, from: bytes).writable)
    }
    func testPathsRejectTraversalAndMultipartInjection() throws {
        XCTAssertEqual(try SeafilePolicy.path("Photos/2026/09"), "/Photos/2026/09")
        for path in ["../file", "Photos/../file", "/root", "folder//file", "file\r\nheader"] {
            XCTAssertThrowsError(try SeafilePolicy.path(path))
        }
    }
    func testSMBAndSeafileKeepSeparateDestinations() {
        let suite = "SeafileTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), address = URL(string: "https://unraid.example.com")!
        let smb = PhotoBackupStore(serverID: id, address: address, defaults: defaults)
        let sea = PhotoBackupStore(serverID: id, address: address, usesSeafile: true, defaults: defaults)
        smb.share = "photos"; smb.folder = "Existing"
        sea.share = "11111111-2222-3333-4444-555555555555"; sea.folder = "New"
        XCTAssertEqual(PhotoBackupStore(serverID: id, address: address, defaults: defaults).folder, "Existing")
        XCTAssertEqual(PhotoBackupStore(serverID: id, address: address, usesSeafile: true, defaults: defaults).folder, "New")
    }
    func testDockerFailureDoesNotClaimThereAreNoApps() {
        let message = AppStore.containerRefreshMessage(AppError.message("connect ECONNREFUSED /var/run/docker.sock"), hasPreviousApps: false)
        XCTAssertTrue(message.contains("Docker service is unavailable"))
        XCTAssertFalse(message.contains("last loaded list"))
    }
}

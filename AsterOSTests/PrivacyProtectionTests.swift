import XCTest
import WebKit
@testable import AsterOS

final class PrivacyProtectionTests: XCTestCase {
    func testFilesRequirePrivateDestinationAndActiveConnection() {
        for host in ["192.168.1.10", "tower.local", "example.com", "example.ts.net.attacker.com", "100.128.0.1"] {
            XCTAssertFalse(PrivateTransportPolicy.permitsFiles(host: host, connected: true))
        }
        for host in ["tower.example.ts.net", "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"] {
            XCTAssertTrue(PrivateTransportPolicy.permitsFiles(host: host, connected: true))
            XCTAssertFalse(PrivateTransportPolicy.permitsFiles(host: host, connected: false))
        }
    }
    func testWebRequiresExactProtectedHostForHTTP() {
        let host = "tower.example.ts.net"
        for connected in [true, false] {
            for address in ["http://example.com", "http://tower.example.ts.net.attacker.com", "http://100.64.0.1", "https://user:secret@example.com", "file:///tmp/photo"] {
                XCTAssertFalse(PrivateTransportPolicy.permitsWeb(URL(string: address)!, connected: connected, privateHost: host))
            }
            XCTAssertTrue(PrivateTransportPolicy.permitsWeb(URL(string: "https://example.com")!, connected: connected))
            XCTAssertEqual(PrivateTransportPolicy.permitsWeb(URL(string: "http://tower.example.ts.net:8080/path")!, connected: connected, privateHost: host), connected)
        }
        XCTAssertFalse(PrivateTransportPolicy.permitsWeb(URL(string: "http://tower.example.ts.net")!, connected: true))
    }
    @MainActor func testWebKitCompilesPrivateResourceRules() async throws {
        for host in [nil, "tower.example.ts.net", "100.64.0.1", "[fd7a:115c:a1e0::1]"] as [String?] {
            let identifier = UUID().uuidString
            let rules = try PrivateTransportPolicy.webRules(privateHost: host)
            let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
            XCTAssertNotNil(list)
            try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
        }
    }
    func testIconSourcesPreferServerAndRespectExternalConsent() {
        let server = URL(string: "https://tower.example.ts.net:444")!
        let cache = "https://tower.example.ts.net:444/state/plugins/dynamix.docker.manager/images/Plex-icon.png"
        XCTAssertEqual(AppIconPolicy.candidates(icon: "https://cdn.example/icon.png", name: "Plex", server: server, allowExternal: false).map(\.absoluteString), [cache])
        XCTAssertEqual(AppIconPolicy.candidates(icon: "https://cdn.example/icon.png", name: "Plex", server: server, allowExternal: true).map(\.absoluteString), [cache, "https://cdn.example/icon.png"])
        XCTAssertEqual(AppIconPolicy.candidates(icon: "/icons/plex.png", name: "Plex", server: server, allowExternal: false).first?.absoluteString, "https://tower.example.ts.net:444/icons/plex.png")
        for icon in ["https://tower.example.ts.net.evil/icon.png", "https://tower.example.ts.net:445/icon.png", "https://user:password@tower.example.ts.net:444/icon.png", "http://cdn.example/icon.png"] {
            XCTAssertTrue(AppIconPolicy.candidates(icon: icon, name: "../escape", server: server, allowExternal: false).isEmpty)
        }
    }
    func testPrivateAppChoicePreservesPortPathAndQuery() throws {
        let source = try XCTUnwrap(URL(string: "http://192.168.1.209:7878/radarr/path?q=test#details"))
        let server = try XCTUnwrap(URL(string: "https://tower.example.ts.net:444"))
        XCTAssertEqual(PrivateAppAddress.replacingHost(of: source, with: server)?.absoluteString,
                       "http://tower.example.ts.net:7878/radarr/path?q=test#details")
        let saved = SavedApp(name: "Radarr", url: try XCTUnwrap(PrivateAppAddress.replacingHost(of: source, with: server)), containerID: "radarr")
        let restored = try JSONDecoder().decode(SavedApp.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored, saved)
        XCTAssertNil(PrivateAppAddress.replacingHost(of: source, with: URL(string: "https://example.com")!))
        XCTAssertNil(PrivateAppAddress.replacingHost(of: URL(string: "http://user:secret@192.168.1.209")!, with: server))
    }
    func testArtworkCookiesAreRestrictedToServerImagePaths() {
        let server = URL(string: "https://tower.example.ts.net:444")!
        XCTAssertTrue(AppIconPolicy.mayAuthenticate(URL(string: "https://tower.example.ts.net:444/state/plugins/dynamix.docker.manager/images/Plex-icon.png")!, server: server))
        for address in ["https://cdn.example/icon.png", "https://tower.example.ts.net:445/plugins/icon.png", "https://tower.example.ts.net:444/update.php", "https://tower.example.ts.net:444/other/icon.png"] {
            XCTAssertFalse(AppIconPolicy.mayAuthenticate(URL(string: address)!, server: server))
        }
    }
    func testCleanupRemovesOnlyOwnedTransferDirectoriesAndDoesNotFollowLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("keep")
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let original = unrelated.appendingPathComponent("photo.jpg")
        try Data([1,2,3]).write(to: original)
        for prefix in ["asteros-photos-", "AsterOS-"] {
            let abandoned = root.appendingPathComponent(prefix + UUID().uuidString)
            try manager.createDirectory(at: abandoned, withIntermediateDirectories: true)
            try Data([4,5]).write(to: abandoned.appendingPathComponent("partial"))
        }
        let link = root.appendingPathComponent("AsterOS-" + UUID().uuidString)
        try manager.createSymbolicLink(at: link, withDestinationURL: unrelated)
        let similar = root.appendingPathComponent("asteros-photos-not-a-uuid")
        try Data([9]).write(to: similar)
        try PrivateTemporaryFiles.removeAbandoned(in: root)
        XCTAssertEqual(try Data(contentsOf: original), Data([1,2,3]))
        XCTAssertTrue(manager.fileExists(atPath: similar.path))
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: root.path)), Set(["keep", link.lastPathComponent, similar.lastPathComponent]))
    }
}

import XCTest
@testable import AsterOS

@MainActor final class LocalFileTests: XCTestCase {
    func testLegacyConnectionDoesNotGainLocalConsent() throws {
        let old = ShareConnection(host: "192.168.1.7", username: "tester")
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(ShareConnection.self, from: data)
        XCTAssertFalse(ShareTransport.isLocal(decoded))
        XCTAssertThrowsError(try ShareTransport.validate(decoded))
    }
    func testLocalConsentPersistsAndBlocksCellular() throws {
        let local = ShareConnection(host: "192.168.1.7", username: "tester", allowLocalNetwork: true)
        let decoded = try JSONDecoder().decode(ShareConnection.self, from: JSONEncoder().encode(local))
        XCTAssertTrue(ShareTransport.isLocal(decoded))
        XCTAssertNoThrow(try ShareTransport.validate(decoded))
        XCTAssertTrue(ShareTransport.parameters(for: decoded).prohibitedInterfaceTypes?.contains(.cellular) == true)
    }
    func testConsentCannotAllowPublicOrTailnetDirectConnections() {
        for host in ["8.8.8.8", "100.89.37.110", "server.example.com", "server.ts.net", "192.168.1.7.evil.com", "127.0.0.1"] {
            XCTAssertFalse(ShareTransport.isLocal(ShareConnection(host: host, username: "tester", allowLocalNetwork: true)))
        }
    }
}

import XCTest
@testable import AsterOS

final class LocalHTTPTests: XCTestCase {
    func testPrivateRangesAndAmbiguousHosts() {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.7"] {
            XCTAssertTrue(LocalHTTPPolicy.isPrivateIPv4(host))
        }
        for host in ["8.8.8.8", "127.0.0.1", "169.254.1.1", "172.15.0.1", "172.32.0.1", "192.168.1.7.evil.com", "192.168.001.7", "3232235783", "0xc0a80107", "192.168.1.256", "tower.local", "100.64.0.1"] {
            XCTAssertFalse(LocalHTTPPolicy.isPrivateIPv4(host), host)
        }
    }
    func testConsentIsExactOriginPersistentAndRevocable() {
        let suite = "LocalHTTPTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "http://192.168.1.7")!
        XCTAssertFalse(LocalHTTPPolicy.approved(url, defaults: defaults))
        LocalHTTPPolicy.setApproved(true, for: url, defaults: defaults)
        XCTAssertTrue(LocalHTTPPolicy.approved(URL(string: "http://192.168.1.7:80/graphql")!, defaults: UserDefaults(suiteName: suite)!))
        for other in ["http://192.168.1.8", "http://192.168.1.7:8080", "https://192.168.1.7", "http://user@192.168.1.7", "http://8.8.8.8"] {
            XCTAssertFalse(LocalHTTPPolicy.approved(URL(string: other)!, defaults: defaults))
        }
        LocalHTTPPolicy.setApproved(false, for: url, defaults: defaults)
        XCTAssertFalse(LocalHTTPPolicy.approved(url, defaults: defaults))
    }
    func testApprovedHTTPAuthorizationAndCookieIsolation() throws {
        let url = URL(string: "http://192.168.254.253:49199")!
        LocalHTTPPolicy.setApproved(true, for: url)
        defer { LocalHTTPPolicy.setApproved(false, for: url) }
        XCTAssertEqual(try AddressPolicy.validate(url.absoluteString), url)
        let request = try UnraidAuthorization(address: url.absoluteString, allowDockerManagement: false)
        XCTAssertTrue(request.isCallback(request.callback))
        XCTAssertTrue(request.isPostLoginLanding(url.appendingPathComponent("Main")))
        let https = URL(string: request.callback.absoluteString.replacingOccurrences(of: "http:", with: "https:"))!
        XCTAssertFalse(request.isCallback(https))
        XCTAssertFalse(CatalogPolicy.sameOrigin(url, URL(string: "http://192.168.254.253:49200")!))
        XCTAssertTrue(TerminalPolicy.allows(url.appendingPathComponent("webterminal/"), server: url))
        LocalHTTPPolicy.setApproved(false, for: url)
        XCTAssertThrowsError(try AddressPolicy.validate(url.absoluteString))
        XCTAssertFalse(request.isCallback(request.callback))
    }
    func testCertificateRecoveryDoesNotEchoCredentials() {
        let e = NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [NSLocalizedDescriptionKey: "secret-api-key"])
        let message = ConnectionRecovery.message(e)
        XCTAssertTrue(message.contains("API key has not been checked"))
        XCTAssertFalse(message.contains("secret-api-key"))
    }
}

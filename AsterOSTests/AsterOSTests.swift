import XCTest
@testable import AsterOS

final class AsterOSTests: XCTestCase {
    func testCredentialBearingAddressesAreRejected() {
        for input in ["http://tower.local", "https://user:secret@host.test", "https://host.test?token=secret", "https://host.test/#login", "not a URL"] {
            XCTAssertThrowsError(try AddressPolicy.validate(input), input)
        }
    }
    func testHTTPSAddressPreservesPortAndBasePath() throws {
        let base = try AddressPolicy.validate(" https://tower.example:8443/unraid ")
        XCTAssertEqual(AddressPolicy.endpoint(base).absoluteString, "https://tower.example:8443/unraid/graphql")
        XCTAssertEqual(AddressPolicy.endpoint(try AddressPolicy.validate("https://tower.example/graphql")).absoluteString, "https://tower.example/graphql")
    }
    func testCapacityIsKilobytesNotDiskCount() {
        let value = Capacity(free: "512", used: "512", total: "1024")
        XCTAssertEqual(value.fraction, 0.5)
        XCTAssertEqual(Capacity.displayKB("1"), ByteCountFormatter.string(fromByteCount: 1024, countStyle: .file))
        XCTAssertEqual(Capacity(free: "0", used: "1", total: "0").fraction, 0)
        XCTAssertEqual(Capacity.displayKB("-1"), "Unavailable")
    }
    func testGraphQLErrorsRemainVisible() throws {
        let json = Data(#"{"data":null,"errors":[{"message":"Permission denied"}]}"#.utf8)
        let response = try JSONDecoder().decode(Envelope<Overview>.self, from: json)
        XCTAssertNil(response.data)
        XCTAssertEqual(response.errors?.first?.message, "Permission denied")
    }
    private func callback(_ request: UnraidAuthorization, items: [URLQueryItem]) -> URL {
        var url = URLComponents(url: request.callback, resolvingAgainstBaseURL: false)!
        url.queryItems = items
        return url.url!
    }
    func testAuthorizationCallbackIsBoundToOriginStateAndExpiry() throws {
        let request = try UnraidAuthorization(address: "https://server.test:8443/unraid/graphql", allowDockerManagement: false)
        let items = [URLQueryItem(name: "state", value: request.state), URLQueryItem(name: "api_key", value: "test-key")]
        let valid = callback(request, items: items)
        XCTAssertEqual(try request.key(from: valid), "test-key")
        XCTAssertThrowsError(try request.key(from: valid, now: request.created.addingTimeInterval(601)))
        for value in [valid.absoluteString.replacingOccurrences(of: "server.test", with: "attacker.test"),
                      valid.absoluteString.replacingOccurrences(of: ":8443", with: ":9443"),
                      valid.absoluteString.replacingOccurrences(of: "https:", with: "http:"),
                      valid.absoluteString + "#fragment"] {
            XCTAssertThrowsError(try request.key(from: URL(string: value)!))
        }
        XCTAssertThrowsError(try request.key(from: callback(request, items: [URLQueryItem(name: "state", value: "wrong"), items[1]])))
        XCTAssertThrowsError(try request.key(from: callback(request, items: items + [items[1]])))
        XCTAssertThrowsError(try request.key(from: callback(request, items: items + [items[0]])))
        XCTAssertThrowsError(try request.key(from: callback(request, items: [items[0], URLQueryItem(name: "api_key", value: "bad\nkey")])) )
    }
    func testAuthorizationUsesLeastPrivilegeAndManualSafariHasNoCallback() throws {
        let request = try UnraidAuthorization(address: "https://server.test/base/graphql", allowDockerManagement: false)
        let url = request.authorizationURL()
        XCTAssertEqual(url.path, "/base/ApiKeyAuthorize")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scopes" }?.value, "role:viewer")
        let manual = request.authorizationURL(automaticReturn: false)
        XCTAssertFalse(manual.absoluteString.contains("redirect_uri"))
        XCTAssertFalse(manual.absoluteString.contains("state="))
        let writable = try UnraidAuthorization(address: "https://server.test", allowDockerManagement: true)
        let scopes = URLComponents(url: writable.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scopes" }!.value!
        XCTAssertEqual(Set(scopes.split(separator: ",").map(String.init)), Set(["role:viewer", "docker:read", "docker:create", "docker:update", "docker:delete"]))
        XCTAssertFalse(scopes.contains("role:admin"))
    }
    func testRedirectErrorDoesNotDisplaySensitiveLocationData() {
        let response = HTTPURLResponse(url: URL(string: "https://server.test/graphql")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://other.test/private-secret?api_key=secret#token"])!
        let message = UnraidClient.redirectMessage(response: response)
        XCTAssertTrue(message.contains("other.test"))
        XCTAssertFalse(message.contains("private-secret"))
        XCTAssertFalse(message.contains("api_key=secret"))
    }
    func testLoginLandingResumesOnlyOnSelectedServer() throws {
        let request = try UnraidAuthorization(address: "https://server.test:8443", allowDockerManagement: false)
        XCTAssertTrue(request.isPostLoginLanding(URL(string: "https://server.test:8443/Main")!))
        XCTAssertTrue(request.isPostLoginLanding(URL(string: "https://server.test:8443/Dashboard")!))
        for value in ["https://other.test:8443/Main", "https://server.test/Main", "http://server.test:8443/Main", "https://server.test:8443/login", "https://server.test:8443/ApiKeyAuthorize"] {
            XCTAssertFalse(request.isPostLoginLanding(URL(string: value)!))
        }
    }
    func testKeychainCanSaveReadUpdateAndRemoveCredential() throws {
        let id = UUID()
        defer { try? CredentialStore.remove(id) }
        try CredentialStore.save("asteros-test-value", for: id)
        XCTAssertEqual(try CredentialStore.read(id), "asteros-test-value")
        try CredentialStore.save("asteros-updated-test-value", for: id)
        XCTAssertEqual(try CredentialStore.read(id), "asteros-updated-test-value")
        try CredentialStore.remove(id)
        XCTAssertThrowsError(try CredentialStore.read(id))
    }
}

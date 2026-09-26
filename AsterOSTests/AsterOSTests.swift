import XCTest
@testable import AsterOS

final class AsterOSTests: XCTestCase {
    func testPhotoFoldersAreReadableStableAndPathSafe() throws {
        let date = ISO8601DateFormatter().date(from: "2026-09-26T16:31:00Z")!
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(PhotoBackupPolicy.folders(date: date, layout: .monthly, timeZone: zone), ["2026", "09"])
        XCTAssertEqual(PhotoBackupPolicy.folders(date: date, layout: .daily, timeZone: zone), ["2026", "09", "26"])
        XCTAssertEqual(PhotoBackupPolicy.folders(date: nil, layout: .monthly, timeZone: zone), ["Unknown date"])
        let name = try PhotoBackupPolicy.resourceName(date: date, originalName: "IMG_1624.HEIC", identity: "abcdef0123456789", index: 0, timeZone: zone)
        XCTAssertEqual(name, "2026-09-26 16-31-00 [abcdef0123456789]-0-IMG_1624.HEIC")
        XCTAssertThrowsError(try PhotoBackupPolicy.resourceName(date: date, originalName: "../bad.jpg", identity: "abc", index: 0, timeZone: zone))
        let other = try PhotoBackupPolicy.resourceName(date: date, originalName: "IMG_1624.HEIC", identity: "anotherasset", index: 0, timeZone: zone)
        XCTAssertNotEqual(name, other)
    }

    func testMonthlyPhotoNamesSortByCaptureDayThenTime() throws {
        let dates = ["2026-09-01T09:00:00Z", "2026-09-02T08:00:00Z", "2026-09-02T17:00:00Z", "2026-09-10T01:00:00Z", "2026-09-30T23:00:00Z"]
        let names = try dates.enumerated().map { index, value in
            try PhotoBackupPolicy.resourceName(date: ISO8601DateFormatter().date(from: value), originalName: "IMG_\(100-index).HEIC", identity: "asset\(index)", index: 0, timeZone: TimeZone(secondsFromGMT: 0)!)
        }
        // Match the Files view's natural name ordering, regardless of camera numbering.
        let unordered = [names[4], names[2], names[0], names[3], names[1]]
        XCTAssertEqual(unordered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, names)
    }

    func testSeparatedDestinationsFindPriorLayouts() {
        let date = ISO8601DateFormatter().date(from: "2026-09-26T16:31:00Z")!
        let zone = TimeZone(secondsFromGMT: 0)!
        let video = PhotoBackupPolicy.destinations(date: date, layout: .monthly, isVideo: true, timeZone: zone)
        XCTAssertEqual(video, [["Videos", "2026", "09"], ["Videos", "2026", "09", "26"], ["2026", "09"], ["2026", "09", "26"]])
        XCTAssertEqual(PhotoBackupPolicy.destinations(date: date, layout: .daily, isVideo: false, timeZone: zone).first, ["Photos", "2026", "09", "26"])
        XCTAssertEqual(PhotoBackupPolicy.destinations(date: nil, layout: .monthly, isVideo: false, timeZone: zone), [["Photos", "Unknown date"], ["Unknown date"]])
    }

    func testSavedBackupStateSurvivesSerialization() throws {
        let checkpoint = PhotoBackupCheckpoint(share: "Media", folder: "Backup", completed: 27, total: 100, finished: false)
        let restored = try JSONDecoder().decode(PhotoBackupCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(restored.completed, 27)
        XCTAssertEqual(restored.total, 100)
        XCTAssertEqual(restored.share, "Media")
        XCTAssertFalse(restored.finished)
        // A receipt read from disk remains authoritative after the in-memory run is gone.
        let receipt = PhotoBackupReceipt(version: 1, asset: "same-asset", files: [.init(name: "photo.HEIC", size: 12), .init(name: "paired.MOV", size: 30)])
        let recovered = try JSONDecoder().decode(PhotoBackupReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertTrue(recovered.matches(["photo.HEIC": 12, "paired.MOV": 30], asset: "same-asset"))
        XCTAssertFalse(recovered.matches(["photo.HEIC": 12], asset: "same-asset"))
        XCTAssertFalse(recovered.matches(["photo.HEIC": 12, "paired.MOV": 30], asset: "edited-asset"))
    }

    func testContainerWebUIUsesConfiguredURLAndMappedTemplatePorts() {
        let server = URL(string: "https://unraid.example.ts.net:4443")!
        var container = Container(id: "test", names: ["/App"], state: "RUNNING", status: "", webUiUrl: "http://192.168.1.209:8096/web")
        XCTAssertEqual(container.webAddress(server: server)?.absoluteString, "http://192.168.1.209:8096/web")
        container.labels = ["net.unraid.docker.webui": "http://[IP]:[PORT:8080]/web?view=home#top"]
        container.ports = [ContainerPort(privatePort: 8080, publicPort: 8096, type: "TCP")]
        container.hostConfig = ContainerHostConfig(networkMode: "bridge")
        XCTAssertEqual(container.webAddress(server: server)?.absoluteString, "http://unraid.example.ts.net:8096/web?view=home#top")
        container.hostConfig = ContainerHostConfig(networkMode: "br0")
        container.networkSettings = ContainerNetworks(Networks: ["br0": .init(IPAddress: "192.168.1.50")])
        XCTAssertEqual(container.webAddress(server: server)?.host, "192.168.1.50")
        container.labels = nil
        container.webUiUrl = "https://app.example.com/login"
        XCTAssertEqual(container.webAddress(server: server)?.absoluteString, "https://app.example.com/login")
        container.webUiUrl = ""
        container.labels = ["net.unraid.docker.webui": "http://tower:8080"]
        XCTAssertEqual(container.webAddress(server: server)?.absoluteString, "http://tower:8080")
    }

    func testWebUIRejectsCredentialsAndNonWebSchemesWithoutRelaxingAPI() {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com", "ftp://example.com"] {
            XCTAssertFalse(AppWebPolicy.allows(URL(string: value)!))
        }
        XCTAssertTrue(AppWebPolicy.allows(URL(string: "http://tower:8080")!))
        XCTAssertThrowsError(try AddressPolicy.validate("http://tower:8080"))
        let container = Container(id: "test", names: [], state: "RUNNING", status: "", webUiUrl: "http://[IP]:[PORT:99999]")
        XCTAssertNil(container.webAddress(server: URL(string: "https://tower")))
    }

    func testBackupReceiptRequiresEveryResourceAndSafeNames() {
        let receipt = PhotoBackupReceipt(version: 1, asset: "asset", files: [.init(name: "photo.heic", size: 12), .init(name: "paired.mov", size: 30)])
        XCTAssertTrue(receipt.matches(["photo.heic": 12, "paired.mov": 30], asset: "asset"))
        XCTAssertFalse(receipt.matches(["photo.heic": 12], asset: "asset"))
        XCTAssertFalse(receipt.matches(["photo.heic": 12, "paired.mov": 29], asset: "asset"))
        XCTAssertFalse(receipt.matches(["photo.heic": 12, "paired.mov": 30], asset: "different"))
        XCTAssertFalse(PhotoBackupReceipt(version: 1, asset: "asset", files: [.init(name: "../outside", size: 1)]).matches(["../outside": 1], asset: "asset"))
    }
    func testBackupIdentitySeparatesChangedAssets() {
        let date = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(PhotoBackupPolicy.identifier("one", modified: date), PhotoBackupPolicy.identifier("one", modified: date))
        XCTAssertNotEqual(PhotoBackupPolicy.identifier("one", modified: date), PhotoBackupPolicy.identifier("two", modified: date))
        XCTAssertNotEqual(PhotoBackupPolicy.identifier("one", modified: date), PhotoBackupPolicy.identifier("one", modified: date.addingTimeInterval(1)))
    }

    func testTailnetRoutesDoNotCapturePublicOrLANHosts() {
        for host in ["unraid.tail123.ts.net", "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::42"] { XCTAssertTrue(TailnetPolicy.contains(host), host) }
        for host in ["login.tailscale.com", "tailscale.com", "evilts.net", "unraid.tail.ts.net.evil.test", "192.168.1.209", "100.63.255.255", "100.128.0.1", "", "ai", "localhost"] { XCTAssertFalse(TailnetPolicy.contains(host), host) }
        XCTAssertFalse(TailnetPolicy.domains.contains(""))
        XCTAssertFalse(TailnetPolicy.domains.isEmpty)
    }
    func testTailnetAuthOnlyOpensOfficialHTTPSLogin() {
        XCTAssertNotNil(TailnetPolicy.loginURL("https://login.tailscale.com/a/example"))
        for value in ["http://login.tailscale.com", "https://login.tailscale.com.evil.test", "https://user:secret@login.tailscale.com", "file:///tmp/test"] { XCTAssertNil(TailnetPolicy.loginURL(value)) }
    }

    func testShareAddressCannotEmbedCredentialsOrRedirectToWeb() throws {
        XCTAssertEqual(try SharePolicy.host(" tower.local "), "tower.local")
        XCTAssertEqual(try SharePolicy.host("smb://192.168.1.20/"), "192.168.1.20")
        for host in ["", "https://server.test", "user:pass@server.test", "smb://server.test/share", "server.test:445", "server.test?token=secret", "server.test#fragment", "bad host", "server.test%2fother"] {
            XCTAssertThrowsError(try SharePolicy.host(host), host)
        }
    }
    func testShareFileNamesCannotEscapeDestination() throws {
        XCTAssertEqual(try SharePolicy.child("photo.jpg", in: "Photos/2026"), "Photos/2026/photo.jpg")
        XCTAssertEqual(try SharePolicy.name("Family photos"), "Family photos")
        for name in ["", ".", "..", "../secret", "folder/file", "folder\\file", "file:stream", "name\n", "name.", "name ", "*"] {
            XCTAssertThrowsError(try SharePolicy.name(name), name)
        }
    }

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

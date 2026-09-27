import XCTest
import WebKit
@testable import AsterOS

final class AsterOSTests: XCTestCase {
    @MainActor func testCatalogCacheAppearsBeforeNetworkButCannotInstall() throws {
        let id = UUID(), server = URL(string: "https://cache-test.example:4443")!
        defer { CatalogCache.forget(id) }
        let app = CatalogApp(id: "repo|Example", name: "Example", author: "Author", category: "Media", summary: "Saved listing", icon: "", section: "Discover", note: "")
        CatalogCache.save([app], serverID: id, address: CatalogPolicy.url(server: server))
        let model = CatalogBrowserModel(server: server, serverID: id)
        XCTAssertEqual(model.catalogItems, [app])
        XCTAssertTrue(model.catalogReady)
        XCTAssertFalse(model.catalogLive, "Cached metadata must never enable installation")
        XCTAssertTrue(model.catalogRefreshing)
        XCTAssertNil(model.webView.url, "Cache must be available before any network request")
        XCTAssertNil(CatalogCache.load(serverID: UUID(), address: CatalogPolicy.url(server: server)))
        XCTAssertNil(CatalogCache.load(serverID: id, address: URL(string: "https://other.example/Apps")!))
        CatalogCache.forget(id)
        XCTAssertNil(CatalogCache.load(serverID: id, address: CatalogPolicy.url(server: server)))
    }

    @MainActor func testSessionOnlyLoginSurvivesFreshBrowserAndLogoutIsNotRestored() async throws {
        let id = UUID(), server = URL(string: "https://tower.example:4443")!
        defer { try? ServerWebSession.forget(id) }
        let firstStore = WKWebsiteDataStore.nonPersistent()
        let first = ServerWebSession(serverID: id, server: server, dataStore: firstStore)
        try await first.restore()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "tower.example", .path: "/", .name: "unraid_0123456789abcdef0123456789abcdef", .value: "synthetic-test-only", .secure: "TRUE", .discard: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertTrue(cookie.isSessionOnly)
        await firstStore.httpCookieStore.setCookie(cookie)
        await first.capture(); first.stopObserving()
        let freshStore = WKWebsiteDataStore.nonPersistent()
        let reopened = ServerWebSession(serverID: id, server: server, dataStore: freshStore)
        try await reopened.restore()
        let restored = await freshStore.httpCookieStore.allCookies()
        let restoredCookie = try XCTUnwrap(restored.first { $0.name == cookie.name })
        XCTAssertEqual(restoredCookie.value, cookie.value)
        XCTAssertNil(restoredCookie.expiresDate, "Do not manufacture a longer cookie lifetime")
        XCTAssertTrue(restoredCookie.isHTTPOnly)
        await freshStore.httpCookieStore.delete(restoredCookie)
        // WebKit can acknowledge delete before its network process publishes the change.
        // Wait for the observed deletion before asserting the archive's logout behavior.
        var remaining = await freshStore.httpCookieStore.allCookies()
        for _ in 0..<100 where !remaining.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            remaining = await freshStore.httpCookieStore.allCookies()
        }
        XCTAssertTrue(remaining.isEmpty, "WebKit must finish deleting the test cookie")
        await reopened.capture(); reopened.stopObserving()
        let lastStore = WKWebsiteDataStore.nonPersistent()
        let last = ServerWebSession(serverID: id, server: server, dataStore: lastStore)
        try await last.restore()
        let afterLogout = await lastStore.httpCookieStore.allCookies()
        XCTAssertTrue(afterLogout.isEmpty)
        last.stopObserving()
    }
    @MainActor func testSessionArchiveRejectsOtherOriginsAndExpiredCookies() throws {
        let server = URL(string: "https://tower.example:4443")!
        func cookie(domain: String, expiry: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: "/", .name: "unraid_0123456789abcdef0123456789abcdef", .value: "synthetic-test-only", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]
            if let expiry { properties[.expires] = expiry }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let data = try ServerWebSession.encode([cookie(domain: "tower.example"), cookie(domain: "other.example")], server: server)
        XCTAssertEqual(try ServerWebSession.decode(data, server: server).count, 1)
        XCTAssertTrue(try ServerWebSession.decode(data, server: URL(string: "https://tower.example:443")!).isEmpty)
        XCTAssertTrue(try ServerWebSession.decode(data, server: URL(string: "https://other.example:4443")!).isEmpty)
        XCTAssertFalse(ServerWebSession.accepts(try cookie(domain: "tower.example", expiry: Date().addingTimeInterval(-1)), server: server))
        XCTAssertFalse(ServerWebSession.accepts(try cookie(domain: ".example"), server: server))
    }

    @MainActor func testCatalogSessionSurvivesModelRecreationAndIsIsolated() async throws {
        let firstID = UUID(), otherID = UUID()
        let url = URL(string: "https://catalog-session.example")!
        let authorization = try UnraidAuthorization(address: url.absoluteString, allowDockerManagement: true, profileID: firstID)
        let loginStore = CatalogSession.dataStore(serverID: authorization.profileID)
        let first = CatalogBrowserModel(server: url, serverID: firstID)
        XCTAssertEqual(loginStore.identifier, first.webView.configuration.websiteDataStore.identifier)
        XCTAssertNil(first.webView.url, "Present the native screen before starting network requests")
        XCTAssertTrue(first.webView.configuration.websiteDataStore.isPersistent)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "catalog-session.example", .path: "/", .name: "test-session", .value: "test-only", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        await loginStore.httpCookieStore.setCookie(cookie)
        let reopened = CatalogBrowserModel(server: url, serverID: firstID)
        let cookies = await reopened.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "test-session" && $0.value == "test-only" })
        let other = CatalogBrowserModel(server: url, serverID: otherID)
        let isolated = await other.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertFalse(isolated.contains { $0.name == "test-session" })
        await first.webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let cleared = await reopened.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertFalse(cleared.contains { $0.name == "test-session" })
        try CatalogSession.forget(serverID: otherID)
    }

    @MainActor func testShareAccountReferenceSurvivesReconnectionAndForgetClearsAliases() throws {
        let suite = "AsterOS-share-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        let address = URL(string: "https://tower.example:4443")!
        let connection = ShareConnection(host: "tower.example", username: "photos")
        try ShareSettings.save(connection, serverID: a, address: address, defaults: defaults)
        XCTAssertEqual(ShareSettings.load(serverID: b, address: address, defaults: defaults)?.id, connection.id)
        XCTAssertNil(ShareSettings.load(serverID: UUID(), address: URL(string: "https://other.example")!, defaults: defaults))
        let replacement = ShareConnection(host: "tower.example", username: "updated")
        try ShareSettings.save(replacement, serverID: b, address: address, defaults: defaults)
        XCTAssertEqual(ShareSettings.load(serverID: a, address: nil, defaults: defaults)?.id, replacement.id)
        for key in ShareSettings.keys(for: replacement.id, defaults: defaults) { defaults.removeObject(forKey: key) }
        XCTAssertNil(ShareSettings.load(serverID: a, address: address, defaults: defaults))
        XCTAssertNil(ShareSettings.load(serverID: b, address: address, defaults: defaults))
    }

    @MainActor func testPhotoDestinationPathsStayInsideShare() throws {
        XCTAssertEqual(try PhotoDestinationPolicy.components(""), [])
        XCTAssertEqual(try PhotoDestinationPolicy.components("Backups/My Photos"), ["Backups", "My Photos"])
        for bad in ["/Photos", "Photos/", "../Photos", "Photos/../Other", "Photos//Other", "Photos\\Other", ".", "Photos/.."] {
            XCTAssertThrowsError(try PhotoDestinationPolicy.components(bad), bad)
        }
    }
    @MainActor func testPhotoDestinationAndCheckpointSurviveReconnection() throws {
        let suite = "AsterOS-photo-destination-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = UUID(), current = UUID(), next = UUID()
        let legacy = "photoBackup-" + old.uuidString
        defaults.set(["share": "AsterOS", "folder": "AsterOS ICloud Photo Backup"], forKey: legacy)
        defaults.set("daily", forKey: legacy + "-layout")
        defaults.set("America/Chicago", forKey: legacy + "-timeZone")
        let checkpoint = PhotoBackupCheckpoint(share: "AsterOS", folder: "AsterOS ICloud Photo Backup", completed: 314, total: 25270, finished: false)
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: legacy + "-checkpoint")
        let address = URL(string: "https://tower.example:4443")!
        let store = PhotoBackupStore(serverID: current, address: address, knownServerIDs: [current], defaults: defaults)
        XCTAssertEqual(store.completed, 314)
        XCTAssertEqual(store.folder, checkpoint.folder)
        XCTAssertEqual(store.layout, .daily)
        store.folder = "Backups/Family"
        let restarted = PhotoBackupStore(serverID: next, address: address, knownServerIDs: [next], defaults: defaults)
        XCTAssertEqual(restarted.folder, "Backups/Family", "Selection is saved before any upload starts")
        XCTAssertEqual(restarted.completed, 0, "Do not show progress from a different destination")
        restarted.folder = checkpoint.folder
        XCTAssertEqual(restarted.completed, 314)
        let key = PhotoDestinationPolicy.settingsKey(serverID: next, address: address, knownServerIDs: [next], defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: key + "-timeZone"), "America/Chicago")
        XCTAssertNotNil(defaults.object(forKey: legacy), "Keep recovery source")
        restarted.folder = ""
        XCTAssertEqual(PhotoBackupStore(serverID: next, address: address, defaults: defaults).folder, "")
    }
    @MainActor func testPhotoSettingsDoNotGuessBetweenLegacyDestinations() {
        let suite = "AsterOS-photo-isolation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<2 { defaults.set(["share": "Old", "folder": "Photos"], forKey: "photoBackup-" + UUID().uuidString) }
        let id = UUID()
        let key = PhotoDestinationPolicy.settingsKey(serverID: id, address: URL(string: "https://different.example")!, knownServerIDs: [id], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: key))
    }

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

    @MainActor func testAppFoldersPersistAndStaySeparatePerServer() throws {
        let suite = "AsterOS-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = UUID(), other = UUID()
        let store = AppFoldersStore(defaults: defaults)
        store.load(serverID: server)
        let media = try XCTUnwrap(store.create("Media", app: "container:plex"))
        let tools = try XCTUnwrap(store.create("Tools"))
        store.move("container:plex", to: tools)
        XCTAssertTrue(store.layout.folders.first { $0.id == media }!.members.isEmpty)
        let reloaded = AppFoldersStore(defaults: defaults)
        reloaded.load(serverID: server)
        XCTAssertEqual(reloaded.folder(for: "container:plex"), tools)
        reloaded.rename(tools, name: "Utilities")
        reloaded.load(serverID: other)
        XCTAssertTrue(reloaded.layout.folders.isEmpty)
        reloaded.load(serverID: server)
        XCTAssertEqual(reloaded.layout.folders.last?.name, "Utilities")
        reloaded.remove(tools)
        XCTAssertNil(reloaded.folder(for: "container:plex"))
        XCTAssertEqual(reloaded.layout.folders.count, 1)
    }

    @MainActor func testFoldersRecoverAfterServerReAddedAndSurviveRestart() throws {
        let suite = "AsterOS-folder-recovery-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldID = UUID(), newID = UUID(), thirdID = UUID()
        let address = URL(string: "https://tower.example:443")!
        let old = AppFoldersStore(defaults: defaults)
        old.load(serverID: oldID)
        let media = try XCTUnwrap(old.create("Media Management", app: "container:plex"))
        let recovered = AppFoldersStore(defaults: defaults)
        recovered.load(serverID: newID, address: address, knownServerIDs: [newID])
        XCTAssertEqual(recovered.folder(for: "container:plex"), media)
        recovered.rename(media, name: "Media")
        let restarted = AppFoldersStore(defaults: UserDefaults(suiteName: suite)!)
        restarted.load(serverID: thirdID, address: URL(string: "https://TOWER.example/graphql")!, knownServerIDs: [thirdID])
        XCTAssertEqual(restarted.layout.folders.first?.name, "Media")
        XCTAssertEqual(restarted.folder(for: "container:plex"), media)
        XCTAssertNotNil(defaults.data(forKey: "appFolders-" + oldID.uuidString))
        restarted.remove(media)
        restarted.load(serverID: thirdID, address: address, knownServerIDs: [thirdID])
        XCTAssertTrue(restarted.layout.folders.isEmpty, "Do not restore folders the user deliberately deleted")
    }

    @MainActor func testFolderRecoveryDoesNotGuessOrOverwriteCorruptData() throws {
        let suite = "AsterOS-folder-isolation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID(), c = UUID()
        let store = AppFoldersStore(defaults: defaults)
        store.load(serverID: a); store.create("First")
        store.load(serverID: b); store.create("Second")
        let address = URL(string: "https://other.example")!
        store.load(serverID: c, address: address, knownServerIDs: [c])
        XCTAssertTrue(store.layout.folders.isEmpty)
        store.load(serverID: c, address: address, knownServerIDs: [a, c])
        XCTAssertTrue(store.layout.folders.isEmpty)
        let corrupt = Data("invalid layout".utf8)
        defaults.set(corrupt, forKey: AppFoldersStore.addressKey(address))
        store.load(serverID: c, address: address, knownServerIDs: [c])
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.create("Must not overwrite"))
        XCTAssertEqual(defaults.data(forKey: AppFoldersStore.addressKey(address)), corrupt)
    }

    func testRemovalUsesIDVariableAndPreservesDockerImage() throws {
        XCTAssertTrue(UnraidClient.removeContainerMutation.contains("removeContainer(id: $id, withImage: false)"))
        let success = try JSONDecoder().decode(ContainerRemovalData.self, from: Data(#"{"docker":{"removeContainer":true}}"#.utf8))
        XCTAssertTrue(success.docker.removeContainer)
        let rejected = try JSONDecoder().decode(ContainerRemovalData.self, from: Data(#"{"docker":{"removeContainer":false}}"#.utf8))
        XCTAssertFalse(rejected.docker.removeContainer)
    }
    func testCatalogReturnsAfterServerLoginOnlyOnMatchingOrigin() {
        let server = URL(string: "https://tower.example.ts.net:4443/graphql")!
        let catalog = CatalogPolicy.url(server: server)
        XCTAssertEqual(catalog.absoluteString, "https://tower.example.ts.net:4443/Apps")
        XCTAssertEqual(CatalogPolicy.url(server: URL(string: "https://tower.example/base/graphql")!).path, "/base/Apps")
        XCTAssertTrue(CatalogPolicy.returnAfterLogin(URL(string: "https://tower.example.ts.net:4443/Main")!, catalog: catalog, sawLogin: true))
        for value in ["http://tower.example.ts.net:4443/Main", "https://tower.example.ts.net/Main", "https://other.example:4443/Main", "https://tower.example.ts.net:4443/Apps", "https://tower.example.ts.net:4443/UpdateContainer"] {
            XCTAssertFalse(CatalogPolicy.returnAfterLogin(URL(string: value)!, catalog: catalog, sawLogin: true))
        }
        XCTAssertFalse(CatalogPolicy.returnAfterLogin(URL(string: "https://tower.example.ts.net:4443/Main")!, catalog: catalog, sawLogin: false))
    }

    @MainActor func testNativeCatalogReadsDockerCardsWithoutLoginDataOrInstalling() async throws {
        let loaded = expectation(description: "Catalog fixture loaded")
        let delegate = CatalogFixtureLoader(loaded)
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = delegate
        web.loadHTMLString(#"""
        <input type="password" value="never-export-this">
        <div class="ca_holder" data-apppath="/templates/media.xml" data-appname="Media &amp; Photos" data-repository="Example Repo">
          <span class="appDocker"></span><div class="ca_author">Example Author</div>
          <div class="cardCategory">MediaServer</div><div class="cardDesc">Organize photos &amp; video.</div>
          <div class="infoButton" onclick="window.reviewed = true">Info</div>
          <button onclick="window.installed = true">Install</button>
        </div>
        <div class="ca_holder" data-apppath="/plugins/extra" data-appname="Plugin"><span class="appPlugin"></span></div>
        <a class="pageRight" onclick="window.nextPage = true">Next</a><span class="pageLeft pageNavNoClick"></span>
        <script>var data = {searchInProgress: false}; window.installed = false; window.reviewed = false;</script>
        """#, baseURL: URL(string: "https://catalog.invalid/Apps"))
        await fulfillment(of: [loaded], timeout: 10)
        let result = try await web.callAsyncJavaScript(NativeCatalogBridge.snapshot, arguments: [:], in: nil, contentWorld: .page)
        let json = try XCTUnwrap(result as? String)
        XCTAssertFalse(json.contains("never-export-this"))
        let page = try JSONDecoder().decode(NativeCatalogPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.name, "Media & Photos")
        XCTAssertEqual(page.items.first?.author, "Example Author")
        XCTAssertTrue(page.next); XCTAssertFalse(page.previous)
        XCTAssertTrue(page.ready); XCTAssertFalse(page.busy)
        _ = try await web.callAsyncJavaScript(NativeCatalogBridge.review, arguments: ["appID": page.items[0].id], in: nil, contentWorld: .page)
        let reviewed = try await web.evaluateJavaScript("window.reviewed") as? Bool
        let installed = try await web.evaluateJavaScript("window.installed") as? Bool
        XCTAssertEqual(reviewed, true); XCTAssertEqual(installed, false)
        let stale = try await web.callAsyncJavaScript(NativeCatalogBridge.review, arguments: ["appID": "missing"], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(stale, false)
        web.navigationDelegate = nil
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

@MainActor private final class CatalogFixtureLoader: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

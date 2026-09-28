import Foundation
import WebKit
import Security

// WebKit does not retain PHP's session-only login cookie across process exits.
// Keep its original attributes in this-device-only Keychain; never extend expiry.
@MainActor final class ServerWebSession: NSObject, WKHTTPCookieStoreObserver {
    private let serverID: UUID
    private let server: URL
    private let dataStore: WKWebsiteDataStore
    private var restored = false
    private var revision = 0
    private var captureTask: Task<Void, Never>?
    var onError: ((String) -> Void)?
    init(serverID: UUID, server: URL, dataStore: WKWebsiteDataStore) {
        self.serverID = serverID; self.server = server; self.dataStore = dataStore
    }
    static func origin(_ url: URL) -> String {
        "https://" + (url.host?.lowercased() ?? "") + ":" + String(url.port ?? 443)
    }
    static func accepts(_ cookie: HTTPCookie, server: URL, now: Date = Date()) -> Bool {
        // Unraid uses unraid_<md5(host)>; never archive SSO or other app cookies.
        server.scheme?.lowercased() == "https" &&
        cookie.domain.lowercased() == server.host?.lowercased() &&
        cookie.name.range(of: "^unraid_[0-9a-f]{32}$", options: .regularExpression) != nil &&
        cookie.path == "/" && cookie.isHTTPOnly &&
        (cookie.expiresDate == nil || cookie.expiresDate! > now)
    }
    static func encode(_ cookies: [HTTPCookie], server: URL) throws -> Data {
        let properties = cookies.filter { accepts($0, server: server) }.map { cookie in
            Dictionary(uniqueKeysWithValues: (cookie.properties ?? [:]).map { ($0.key.rawValue, $0.value) })
        }
        return try PropertyListSerialization.data(fromPropertyList: ["origin": origin(server), "cookies": properties], format: .binary, options: 0)
    }
    static func decode(_ data: Data, server: URL) throws -> [HTTPCookie] {
        guard let archive = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              archive["origin"] as? String == origin(server),
              let properties = archive["cookies"] as? [[String: Any]] else { return [] }
        return properties.compactMap { HTTPCookie(properties: Dictionary(uniqueKeysWithValues: $0.map { (HTTPCookiePropertyKey($0.key), $0.value) })) }
            .filter { accepts($0, server: server) }
    }
    static func artworkRequest(url: URL, server: URL, serverID: UUID) async throws -> URLRequest {
        var request = URLRequest(url: url)
        guard AppIconPolicy.mayAuthenticate(url, server: server) else { return request }
        let live = await CatalogSession.dataStore(serverID: serverID).httpCookieStore.allCookies()
        var cookies = live.filter { accepts($0, server: server) }
        if cookies.isEmpty, let data = try read(serverID) { cookies = try decode(data, server: server) }
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
    func restore() async throws {
        guard !restored else { return }
        if let data = try Self.read(serverID) {
            let saved = try Self.decode(data, server: server)
            let current = await dataStore.httpCookieStore.allCookies()
            for cookie in saved where !current.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) {
                await dataStore.httpCookieStore.setCookie(cookie)
            }
        }
        restored = true
        dataStore.httpCookieStore.add(self)
        await capture()
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { await capture() }
    }
    func capture() async {
        guard restored else { return }
        revision += 1
        if let pending = captureTask { await pending.value; return }
        let pending = Task { [self] in
            defer { captureTask = nil }
            while restored && !Task.isCancelled {
                let token = revision
                let cookies = await dataStore.httpCookieStore.allCookies()
                guard restored, !Task.isCancelled else { return }
                // Cookie notifications can overlap an explicit save. Drain the latest
                // snapshot before any caller returns, especially immediately after logout.
                if token != revision { continue }
                do {
                    let relevant = cookies.filter { Self.accepts($0, server: server) }
                    if relevant.isEmpty { try Self.forget(serverID) }
                    else { try Self.write(try Self.encode(relevant, server: server), id: serverID) }
                } catch { onError?("Your server session could not be saved securely. Unlock your device and retry.") }
                return
            }
        }
        captureTask = pending
        await pending.value
    }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AsterOS.UnraidWebSession", kSecAttrAccount as String: id.uuidString]
    }
    private static func read(_ id: UUID) throws -> Data? {
        var item = query(id); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AppError.message("Unlock your device to restore your server session.") }
        return data
    }
    private static func write(_ data: Data, id: UUID) throws {
        var item = query(id); item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw AppError.message("Unable to save server session.") }
        } else if status != errSecSuccess { throw AppError.message("Unable to save server session.") }
    }
    static func forget(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("Unable to remove the saved server session. Unlock this device and retry.") }
    }
    func stopObserving() { dataStore.httpCookieStore.remove(self); revision += 1; restored = false }
}

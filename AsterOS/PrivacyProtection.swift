import Foundation

/// Transport policy is checked before credentials or requests are submitted.
enum PrivateTransportPolicy {
    static func permitsFiles(host: String, connected: Bool) -> Bool {
        connected && TailnetPolicy.contains(host)
    }
    static func permitsWeb(_ url: URL, connected: Bool, privateHost: String? = nil) -> Bool {
        guard AppWebPolicy.allows(url) else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard connected, let privateHost, TailnetPolicy.contains(privateHost) else { return false }
        return url.host?.lowercased() == privateHost.lowercased()
    }
    static func webRules(privateHost: String?) throws -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^http://"], "action": ["type": "block"]]
        ]
        if let privateHost, TailnetPolicy.contains(privateHost) {
            let host = NSRegularExpression.escapedPattern(for: privateHost)
            rules.append(["trigger": ["url-filter": "^http://" + host + "(:[0-9]+)?/", "url-filter-is-case-sensitive": false],
                          "action": ["type": "ignore-previous-rules"]])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }
}

enum PrivateTemporaryFiles {
    static func owns(_ name: String) -> Bool {
        for prefix in ["asteros-photos-", "AsterOS-"] where name.hasPrefix(prefix) {
            if UUID(uuidString: String(name.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }
    /// Called only once at process launch, before any new transfers can start.
    static func removeAbandoned(in root: URL = FileManager.default.temporaryDirectory) throws {
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) where owns(item.lastPathComponent) {
            // Never follow a link outside our temporary directory.
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: item)
        }
    }
}


// Native artwork never follows redirects or attaches API/server credentials.
enum AppIconPolicy {
    static func candidates(icon: String?, name: String, server: URL?, allowExternal: Bool) -> [URL] {
        var result: [URL] = []
        let supplied = icon.flatMap { URL(string: $0, relativeTo: server)?.absoluteURL }
        func safe(_ url: URL) -> Bool {
            url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
        }
        if let supplied, safe(supplied), let server, CatalogPolicy.sameOrigin(supplied, server) {
            result.append(supplied)
        }
        if let server, safe(server),
           name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil,
           let cached = URL(string: "/state/plugins/dynamix.docker.manager/images/", relativeTo: server)?.absoluteURL {
            result.append(cached.appendingPathComponent(name + "-icon.png"))
        }
        if allowExternal, let supplied, safe(supplied), !result.contains(supplied) { result.append(supplied) }
        return result
    }
}

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

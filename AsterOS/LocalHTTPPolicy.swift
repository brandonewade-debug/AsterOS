import Foundation

/// Explicit, device-local consent for one RFC1918 IPv4 host and port.
/// Hostnames are intentionally excluded: DNS must not turn a LAN exception into public HTTP.
enum LocalHTTPPolicy {
    private static let key = "approvedLocalHTTPOrigins"
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var bytes: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part), (0...255).contains(n), String(n) == part else { return false }
            bytes.append(n)
        }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
    }
    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme + "://" + (url.host?.lowercased() ?? "") + ":" + String(url.port ?? (scheme == "https" ? 443 : 80))
    }
    static func eligible(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.user == nil && url.password == nil &&
        isPrivateIPv4(url.host ?? "") && (1...65535).contains(url.port ?? 80)
    }
    static func approved(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        eligible(url) && (defaults.stringArray(forKey: key) ?? []).contains(origin(url))
    }
    static func setApproved(_ enabled: Bool, for url: URL, defaults: UserDefaults = .standard) {
        guard eligible(url) else { return }
        var entries = Set(defaults.stringArray(forKey: key) ?? [])
        if enabled { entries.insert(origin(url)) } else { entries.remove(origin(url)) }
        defaults.set(entries.sorted(), forKey: key)
    }
    static func permits(_ url: URL) -> Bool {
        url.user == nil && url.password == nil && (url.scheme?.lowercased() == "https" || approved(url))
    }
}

enum ConnectionRecovery {
    static func message(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && [-1200, -1201, -1202, -1203, -1204].contains(e.code) {
            return "The server’s HTTPS certificate could not be verified. Your API key has not been checked. Use the certificate URL from Unraid Settings → Management Access, or return to connection setup and explicitly allow an HTTP private IP address if your server supports HTTP. Safari certificate exceptions do not carry over into AsterOS."
        }
        return "Unable to connect (code \(e.code)). Check the server address, port, and Local Network permission in iOS Settings. Then retry."
    }
}

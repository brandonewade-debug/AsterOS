import Foundation
import Network
import WireGuardKit

enum VPNConfigurationError: LocalizedError {
    case invalid, routes, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid: return "This is not a supported WireGuard peer configuration. Import a client .conf file with one server peer, an endpoint, keys and tunnel addresses."
        case .routes: return "Use a remote-access configuration that routes only private server or LAN addresses. Full internet tunnels and custom DNS are not supported in this preview."
        case .keychain(let status): return "Unable to access the VPN credential securely (\(status)). Check the app’s signing and Keychain permissions."
        }
    }
}

enum VPNConfiguration {
    // Strict client-only import: never execute wg-quick hooks or accept unknown options.
    static func parse(_ text: String) throws -> TunnelConfiguration {
        guard text.utf8.count <= 65536 else { throw VPNConfigurationError.invalid }
        var sections: [[String: String]] = []
        for line in text.components(separatedBy: .newlines) {
            let value = String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value == "[Interface]" {
                guard sections.isEmpty else { throw VPNConfigurationError.invalid }
                sections.append([:]); continue
            }
            if value == "[Peer]" {
                guard sections.count == 1 else { throw VPNConfigurationError.invalid }
                sections.append([:]); continue
            }
            guard !sections.isEmpty, let separator = value.firstIndex(of: "=") else { throw VPNConfigurationError.invalid }
            let key = value[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let item = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let allowed: Set<String> = sections.count == 1 ? ["privatekey", "address", "mtu", "listenport", "dns"] : ["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"]
            guard allowed.contains(key), sections[sections.count - 1][key] == nil, !item.isEmpty else { throw VPNConfigurationError.invalid }
            sections[sections.count - 1][key] = item
        }
        guard sections.count == 2,
              let privateKey = sections[0]["privatekey"].flatMap(PrivateKey.init(base64Key:)),
              let publicKey = sections[1]["publickey"].flatMap(PublicKey.init(base64Key:)),
              let endpoint = sections[1]["endpoint"].flatMap(Endpoint.init(from:)),
              let address = sections[0]["address"], let routes = sections[1]["allowedips"] else { throw VPNConfigurationError.invalid }
        guard sections[0]["dns"] == nil else { throw VPNConfigurationError.routes }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = try ranges(address)
        if let value = sections[0]["mtu"] {
            guard let mtu = UInt16(value), (1280...9000).contains(mtu) else { throw VPNConfigurationError.invalid }
            interface.mtu = mtu
        }
        if let value = sections[0]["listenport"] {
            guard let port = UInt16(value) else { throw VPNConfigurationError.invalid }
            interface.listenPort = port
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        peer.endpoint = endpoint
        peer.allowedIPs = try ranges(routes)
        guard peer.allowedIPs.allSatisfy(privateRoute) else { throw VPNConfigurationError.routes }
        if let value = sections[1]["presharedkey"] {
            guard let key = PreSharedKey(base64Key: value) else { throw VPNConfigurationError.invalid }
            peer.preSharedKey = key
        }
        if let value = sections[1]["persistentkeepalive"] {
            guard let interval = UInt16(value) else { throw VPNConfigurationError.invalid }
            peer.persistentKeepAlive = interval
        }
        return TunnelConfiguration(name: "AsterOS", interface: interface, peers: [peer])
    }
    private static func ranges(_ value: String) throws -> [IPAddressRange] {
        try value.components(separatedBy: ",").map {
            let item = $0.trimmingCharacters(in: .whitespaces)
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let prefix = Int(parts[1]), let range = IPAddressRange(from: item),
                  prefix >= 0, prefix <= (range.address is IPv4Address ? 32 : 128) else { throw VPNConfigurationError.invalid }
            return range
        }
    }
    static func privateRoute(_ range: IPAddressRange) -> Bool {
        let bytes = [UInt8](range.address.rawValue)
        let prefix = range.networkPrefixLength
        if bytes.count == 4 {
            return (bytes[0] == 10 && prefix >= 8) ||
                (bytes[0] == 172 && (16...31).contains(bytes[1]) && prefix >= 12) ||
                (bytes[0] == 192 && bytes[1] == 168 && prefix >= 16) ||
                (bytes[0] == 100 && (64...127).contains(bytes[1]) && prefix >= 10)
        }
        return bytes.count == 16 && bytes[0] & 0xfe == 0xfc && prefix >= 7
    }
}

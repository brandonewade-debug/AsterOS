import Foundation

struct ServerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: URL
    var connection: ConnectionKind
    var apps: [SavedApp] = []
}
enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case custom = "Custom URL", local = "Local / VPN", connect = "Unraid Connect URL"
    var id: String { rawValue }
}
struct SavedApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: URL
    var symbol = "square.stack.3d.up.fill"
    var containerID: String?
}
enum AddressPolicy {
    static func validate(_ input: String) throws -> URL {
        guard let c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              let url = c.url, LocalHTTPPolicy.permits(url) else {
            throw AppError.message("Use HTTPS, or explicitly allow HTTP for this private IPv4 address in connection setup. Do not include credentials, a query, or a fragment.")
        }
        return url
    }
    static func endpoint(_ base: URL) -> URL {
        base.lastPathComponent == "graphql" ? base : base.appendingPathComponent("graphql")
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
struct Envelope<T: Decodable>: Decodable {
    var data: T?
    var errors: [GraphError]?
}
struct GraphError: Decodable { var message: String }
struct Overview: Decodable {
    var info: SystemInfo
    var array: ArrayInfo
    static let demo = Overview(
        info: SystemInfo(os: OSInfo(hostname: "Demo server", release: "Sample"), cpu: CPUInfo(brand: "Sample processor", cores: 8)),
        array: ArrayInfo(state: "STARTED", capacity: ArrayCapacity(kilobytes: Capacity(free: "8000000000", used: "4000000000", total: "12000000000")), disks: [ArrayDisk(id: "sample", name: "disk1", temp: 32, status: "DISK_OK")]))
}
struct SystemInfo: Decodable { var os: OSInfo; var cpu: CPUInfo }
struct OSInfo: Decodable { var hostname: String?; var release: String? }
struct CPUInfo: Decodable { var brand: String?; var cores: Int? }
struct ArrayInfo: Decodable { var state: String; var capacity: ArrayCapacity; var disks: [ArrayDisk] }
struct ArrayCapacity: Decodable { var kilobytes: Capacity }
struct Capacity: Decodable {
    var free: String; var used: String; var total: String
    var fraction: Double { guard let t = Double(total), t > 0 else { return 0 }; return min(1, max(0, (Double(used) ?? 0) / t)) }
    static func displayKB(_ value: String) -> String {
        guard let kb = Double(value), kb.isFinite, kb >= 0, kb < Double(Int64.max) / 1024 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(kb * 1024), countStyle: .file)
    }
}
struct ArrayDisk: Decodable, Identifiable { var id: String; var name: String?; var temp: Int?; var status: String? }
struct DockerData: Decodable { var docker: DockerList }
struct DockerList: Decodable { var containers: [Container] }
struct ContainerPort: Decodable {
    var ip: String?
    var privatePort: Int?
    var publicPort: Int?
    var type: String?
}
struct ContainerHostConfig: Decodable { var networkMode: String? }
struct ContainerNetworks: Decodable {
    struct Network: Decodable { var IPAddress: String? }
    var Networks: [String: Network]?
}
struct Container: Decodable, Identifiable {
    var id: String; var names: [String]; var state: String; var status: String
    var iconUrl: String?
    var webUiUrl: String?
    var labels: [String: String]?
    var ports: [ContainerPort]?
    var hostConfig: ContainerHostConfig?
    var networkSettings: ContainerNetworks?
    var name: String { (names.first ?? "Container").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
extension Container {
    func iconAddress(server: URL?) -> URL? {
        secureURL(iconUrl ?? labels?["net.unraid.docker.icon"], relativeTo: server)
    }
    func webAddress(server: URL?) -> URL? {
        let template = labels?["net.unraid.docker.webui"]
        // Resolve server-relative templates against the user's reachable server (including Tailscale).
        if let template, template.contains("[IP]"), let url = resolveWebUI(template, server: server) { return url }
        for value in [webUiUrl, template] {
            if let value, let url = resolveWebUI(value, server: server) { return url }
        }
        return nil
    }
    private func resolveWebUI(_ value: String, server: URL?) -> URL? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("[IP]") {
            let mode = hostConfig?.networkMode ?? ""
            let customLAN = mode == "br0" || mode.hasPrefix("br0.") || mode == "eth0" || mode.hasPrefix("eth0.")
            let host = customLAN ? networkSettings?.Networks?[mode]?.IPAddress : server?.host
            guard let host, !host.isEmpty else { return nil }
            value = value.replacingOccurrences(of: "[IP]", with: host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)
        }
        let pattern = #"\[PORT:(\d+)\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let digits = Range(match.range(at: 1), in: value), let whole = Range(match.range, in: value), let port = Int(value[digits]), (1...65535).contains(port) else { return nil }
            let mapped = ports?.first { $0.privatePort == port && $0.type?.uppercased() != "UDP" && $0.publicPort != nil }?.publicPort ?? port
            guard (1...65535).contains(mapped) else { return nil }
            value.replaceSubrange(whole, with: String(mapped))
        }
        guard !value.contains("[IP]"), !value.contains("[PORT"),
              let url = URL(string: value, relativeTo: server)?.absoluteURL,
              AppWebPolicy.allows(url) else { return nil }
        return url
    }
    private func secureURL(_ value: String?, relativeTo server: URL?) -> URL? {
        guard let value, !value.isEmpty, !value.contains("["),
              let url = URL(string: value, relativeTo: server)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
struct MetricsData: Decodable { var metrics: Metrics }
struct Metrics: Decodable {
    var cpu: CPUUsage?; var memory: MemoryUsage?
    static let demo = Metrics(cpu: CPUUsage(percentTotal: 14), memory: MemoryUsage(percentTotal: 38))
}
struct CPUUsage: Decodable { var percentTotal: Double }
struct MemoryUsage: Decodable { var percentTotal: Double }
enum ContainerAction: String { case start, stop }
struct ActionData: Decodable { var docker: ActionResult }
struct ActionResult: Decodable { var start: ContainerIdentity?; var stop: ContainerIdentity? }
struct ContainerIdentity: Decodable { var id: String }

// Container web pages never receive the Unraid API key. Keep server/API validation HTTPS-only.
enum AppWebPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return url.port.map { (1...65535).contains($0) } ?? true
    }
}

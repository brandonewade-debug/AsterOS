import SwiftUI
import WebKit

struct MetricNumber: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(Double.self)) ?? (try? c.decode(String.self)).flatMap(Double.init)
        value = raw.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
struct DashboardNetwork: Decodable, Identifiable {
    let name: String
    let operstate: String?
    let rxSec: Double?
    let txSec: Double?
    let utilizationPercent: Double?
    var id: String { name }
    static func preferred(_ values: [Self]) -> Self? {
        values.first { $0.name == "br0" && $0.operstate == "up" }
        ?? values.first { $0.name == "bond0" && $0.operstate == "up" }
        ?? values.first { $0.name.hasPrefix("eth") && $0.operstate == "up" }
        ?? values.first { $0.operstate == "up" && $0.name != "lo" }
        ?? values.first { $0.name != "lo" }
    }
}
struct DashboardLive: Decodable {
    struct Values: Decodable {
        let cpu: CPUUsage?
        struct Memory: Decodable { let total: MetricNumber?; let used: MetricNumber?; let percentTotal: Double? }
        let memory: Memory?
        let network: [DashboardNetwork]?
    }
    let metrics: Values
}
struct DashboardTemperature: Decodable {
    struct Values: Decodable {
        struct Temperatures: Decodable {
            struct Sensor: Decodable, Identifiable {
                struct Reading: Decodable { let value: Double; let unit: String }
                let id: String; let name: String; let type: String; let current: Reading
            }
            let sensors: [Sensor]
        }
        let temperature: Temperatures?
    }
    let metrics: Values
    var cpuCelsius: Double? {
        let sensors = metrics.temperature?.sensors.filter { ["CPU_PACKAGE", "CPU_CORE"].contains($0.type) } ?? []
        return sensors.compactMap { sensor -> Double? in
            let reading = sensor.current
            guard reading.value.isFinite else { return nil }
            if reading.unit == "CELSIUS" { return reading.value }
            if reading.unit == "FAHRENHEIT" { return (reading.value - 32) * 5 / 9 }
            if reading.unit == "KELVIN" { return reading.value - 273.15 }
            if reading.unit == "RANKINE" { return (reading.value - 491.67) * 5 / 9 }
            return nil
        }.max()
    }
}
struct DashboardPackages: Decodable {
    struct Info: Decodable {
        struct CPU: Decodable {
            struct Packages: Decodable { let totalPower: Double?; let temp: [Double]? }
            let packages: Packages?
        }
        let cpu: CPU
    }
    let info: Info
    var temperature: Double? { info.cpu.packages?.temp?.filter { $0.isFinite && $0 > 0 }.max() }
    var power: Double? { info.cpu.packages?.totalPower.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
}
struct DashboardStorage: Decodable {
    struct Disk: Decodable, Identifiable {
        let id: String; let name: String?; let fsType: String?; let status: String?; let temp: Int?
        let fsSize: MetricNumber?; let fsFree: MetricNumber?; let fsUsed: MetricNumber?
        var fraction: Double? {
            guard let total = fsSize?.value, total > 0, let used = fsUsed?.value else { return nil }
            return min(1, max(0, used / total))
        }
    }
    struct Values: Decodable { let caches: [Disk]; let boot: Disk?; let disks: [Disk] }
    let array: Values
}
struct DashboardGPU: Identifiable {
    let id: String; let name: String
    let utilization: Double?; let temperature: Double?; let power: Double?
    let memory: Double?; let encoder: Double?; let decoder: Double?
    let unavailable: Bool
}
enum GPUStatisticsPolicy {
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue.isFinite && n.doubleValue >= 0 ? n.doubleValue : nil
        }
        guard let string = value as? String,
              let range = string.range(of: #"^\s*[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let number = Double(string[range].trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        return number
    }
    static func percent(_ value: Any?) -> Double? { number(value).flatMap { $0 <= 100 ? $0 : nil } }
    static func configuration(html: String) throws -> Data {
        let regex = try NSRegularExpression(pattern: #"gpustat_statusm\s*\(\s*(\{[^\r\n]*\})\s*\)"#)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let dictionary = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: [String: Any]],
              !dictionary.isEmpty, dictionary.count <= 16 else { throw AppError.message("GPU Statistics must be installed and configured on your Unraid dashboard.") }
        var clean: [String: [String: Any]] = [:]
        for item in dictionary.values {
            guard let vendor = item["vendor"] as? String, ["nvidia", "intel", "amd"].contains(vendor),
                  let id = item["id"] as? String, id.range(of: #"^(?:[0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$"#, options: .regularExpression) != nil,
                  let guid = item["guid"] as? String, guid.count <= 128,
                  guid.range(of: #"^[a-zA-Z0-9:._-]*$"#, options: .regularExpression) != nil else { continue }
            clean[id] = ["vendor": vendor, "id": id, "guid": guid, "panel": clean.count + 1]
        }
        guard !clean.isEmpty else { throw AppError.message("Select a supported GPU in your server’s GPU Statistics settings.") }
        return try JSONSerialization.data(withJSONObject: clean)
    }
    static func decode(_ data: Data) throws -> [DashboardGPU] {
        guard data.count <= 1_000_000,
              let values = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]], values.count <= 16 else { throw AppError.message("GPU Statistics returned an unsupported response.") }
        return values.keys.sorted().compactMap { id in
            guard let v = values[id], let name = v["name"] as? String else { return nil }
            let blocked = (v["vfio"] as? Bool == true) || (v["error"] != nil)
            var temperature = number(v["temp"])
            if (v["temp"] as? String)?.trimmingCharacters(in: .whitespaces).uppercased().hasSuffix("F") == true || v["tempunit"] as? String == "F" { temperature = temperature.map { ($0 - 32) * 5 / 9 } }
            return DashboardGPU(id: id, name: String(name.prefix(160)), utilization: blocked ? nil : percent(v["util"]), temperature: blocked ? nil : temperature, power: blocked ? nil : number(v["power"]), memory: blocked ? nil : percent(v["memutil"]), encoder: blocked ? nil : percent(v["encutil"] ?? v["video"]), decoder: blocked ? nil : percent(v["decutil"]), unavailable: blocked)
        }
    }
}

@MainActor final class GPUStatisticsClient {
    private let profile: ServerProfile
    private let cookies: WKWebsiteDataStore
    private let webSession: ServerWebSession
    private var configuration: Data?
    init(profile: ServerProfile) {
        self.profile = profile
        cookies = CatalogSession.dataStore(serverID: profile.id)
        webSession = ServerWebSession(serverID: profile.id, server: profile.address, dataStore: cookies)
    }
    func stop() { webSession.stopObserving() }
    private func get(_ url: URL) async throws -> Data {
        guard ServerWebSession.origin(url) == ServerWebSession.origin(profile.address), url.user == nil, url.password == nil else { throw AppError.message("Invalid GPU endpoint.") }
        try await webSession.restore()
        let saved = await cookies.httpCookieStore.allCookies().filter { ServerWebSession.accepts($0, server: profile.address) }
        guard !saved.isEmpty else { throw AppError.message("Renew server access in Settings to read GPU Statistics with your server sign-in.") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.proxyConfigurations = try await TailnetStore.shared.prepare(for: profile.address.host)
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: saved)
        // No API key is sent to the plugin; only the exact server's saved session cookie.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_000_000 else {
            configuration = nil
            throw AppError.message("GPU Statistics is unavailable. Check the plugin and renew server access if your sign-in expired.")
        }
        return data
    }
    func fetch() async throws -> [DashboardGPU] {
        let base = TerminalPolicy.base(profile.address)
        if configuration == nil {
            let data = try await get(base.appendingPathComponent("Dashboard"))
            configuration = try GPUStatisticsPolicy.configuration(html: String(decoding: data, as: UTF8.self))
        }
        var url = URLComponents(url: base.appendingPathComponent("plugins/gpustat/gpustatusmulti.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "gpus", value: String(decoding: configuration!, as: UTF8.self))]
        do { return try GPUStatisticsPolicy.decode(try await get(url.url!)) }
        catch { configuration = nil; throw error }
    }
}

@MainActor final class DashboardTelemetry: ObservableObject {
    @Published var live: DashboardLive?
    @Published var temperatures: DashboardTemperature?
    @Published var storage: DashboardStorage?
    @Published var packages: DashboardPackages?
    @Published var gpus: [DashboardGPU] = []
    @Published var gpuMessage: String?
    @Published var gpuUpdated: Date?
    @Published var loading = false
    @Published var updated: Date?
    private var serverID: UUID?
    private var gpu: GPUStatisticsClient?
    private var nextGPUAttempt = Date.distantPast
    static let packagesQuery = "query DashboardPackages { info { cpu { packages { totalPower temp } } } }"
    static let liveQuery = "query DashboardLive { metrics { cpu { percentTotal } memory { total used percentTotal } network { name operstate rxSec txSec utilizationPercent } } }"
    static let temperatureQuery = "query DashboardTemperature { metrics { temperature { sensors { id name type current { value unit } } } } }"
    static let storageQuery = "query DashboardStorage { array { caches { id name fsType status temp fsSize fsFree fsUsed } boot { id name fsType status temp fsSize fsFree fsUsed } disks { id name fsType status temp fsSize fsFree fsUsed } } }"
    func reset(_ profile: ServerProfile?) {
        gpu?.stop(); serverID = profile?.id; gpu = profile.map(GPUStatisticsClient.init)
        live = nil; temperatures = nil; storage = nil; packages = nil; gpus = []; gpuMessage = nil; gpuUpdated = nil; updated = nil; loading = false; nextGPUAttempt = .distantPast
    }
    func refresh(_ profile: ServerProfile) async {
        if serverID != profile.id { reset(profile) }
        guard !loading else { return }
        loading = true; let id = profile.id
        defer { if serverID == id { loading = false } }
        do {
            let client = UnraidClient(profile: profile, key: try CredentialStore.read(id))
            async let l: DashboardLive? = try? client.query(Self.liveQuery)
            async let t: DashboardTemperature? = try? client.query(Self.temperatureQuery)
            async let s: DashboardStorage? = try? client.query(Self.storageQuery)
            async let p: DashboardPackages? = try? client.query(Self.packagesQuery)
            let result = await (l, t, s, p)
            guard !Task.isCancelled, serverID == id else { return }
            live = result.0; temperatures = result.1; storage = result.2; packages = result.3
            updated = result.0 == nil ? nil : Date()
        } catch {
            guard serverID == id, !Task.isCancelled else { return }
            live = nil; temperatures = nil; storage = nil; packages = nil; updated = nil
        }
        guard !Task.isCancelled, serverID == id, Date() >= nextGPUAttempt else { return }
        do {
            let result = try await gpu?.fetch() ?? []
            guard !Task.isCancelled, serverID == id else { return }
            gpus = result; gpuUpdated = Date(); gpuMessage = result.isEmpty ? "No GPU readings returned. Check GPU Statistics on your server." : nil
            nextGPUAttempt = .distantPast
        } catch {
            guard !Task.isCancelled, serverID == id else { return }
            gpus = []; gpuUpdated = nil; gpuMessage = error.localizedDescription; nextGPUAttempt = Date().addingTimeInterval(60)
        }
    }
}

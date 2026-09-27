import SwiftUI

// Formatting never turns a missing sensor or failed request into a zero reading.
enum DashboardDisplay {
    static func percent(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil } }
    static func percentage(_ value: Double?) -> String { percent(value).map { "\(Int($0.rounded()))%" } ?? "—" }
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
    static func memory(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytes(value) + "/s"
    }
    static func temperature(_ celsius: Double?, fahrenheit: Bool) -> String {
        guard let celsius, celsius.isFinite, (-273.15...1000).contains(celsius) else { return "—" }
        return "\(Int((fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded()))°"
    }
}
struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .asterGlass(radius: 30)
    }
}
struct DashboardGauge: View {
    let percent: Double?
    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 5
            for index in 0..<24 {
                let angle = Double(index) / 24 * .pi * 2 - .pi / 2
                let point = CGPoint(x: size.width / 2 + cos(angle) * radius, y: size.height / 2 + sin(angle) * radius)
                let active = DashboardDisplay.percent(percent).map { Double(index) < $0 / 100 * 24 } ?? false
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(active ? .mint : .white.opacity(0.16)))
            }
        }.frame(width: 66, height: 66).accessibilityHidden(true)
    }
}
struct StorageDots: View {
    let fraction: Double?
    var body: some View {
        Canvas { context, size in
            let columns = max(8, Int(size.width / 12)), rows = 4
            for index in 0..<(columns * rows) {
                let x = CGFloat(index / rows) * size.width / CGFloat(columns) + 4
                let y = CGFloat(index % rows) * 12 + 4
                let active = fraction.map { $0.isFinite && Double(index) < min(1, max(0, $0)) * Double(columns * rows) } ?? false
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 5, height: 5)), with: .color(active ? .mint : .white.opacity(0.15)))
            }
        }.frame(height: 48).accessibilityHidden(true)
    }
}
@MainActor struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var vpn: TailnetStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var telemetry = DashboardTelemetry()
    init(telemetry: DashboardTelemetry? = nil) { _telemetry = StateObject(wrappedValue: telemetry ?? DashboardTelemetry()) }
    @State private var setup = false
    @State private var selectedNetwork = ""
    @AppStorage("dashboardFahrenheit") private var fahrenheit = false
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 14), count: typeSize.isAccessibilitySize ? 1 : 2) }
    private var network: DashboardNetwork? {
        let values = telemetry.live?.metrics.network ?? []
        return values.first { $0.name == selectedNetwork } ?? DashboardNetwork.preferred(values)
    }
    private var cpuTemperature: Double? { telemetry.temperatures?.cpuCelsius ?? telemetry.packages?.temperature }
    private var cpu: Double? { telemetry.live?.metrics.cpu?.percentTotal ?? store.metrics?.cpu?.percentTotal }
    private var memory: Double? { telemetry.live?.metrics.memory?.percentTotal ?? store.metrics?.memory?.percentTotal }
    private var networkKey: String { "dashboardInterface-" + (store.selected.map { AppFoldersStore.addressKey($0.address) } ?? "demo") }
    private func refresh() async {
        async let basic: Void = store.refresh()
        if let server = store.selected, !store.demo { await telemetry.refresh(server) }
        await basic
    }
    private func usage(_ title: String, detail: String, value: Double?, footnote: String? = nil) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(detail).font(.subheadline.weight(.semibold)).lineLimit(2).frame(minHeight: 38, alignment: .top)
                Spacer(minLength: 6)
                if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
                HStack(alignment: .bottom) {
                    Text(DashboardDisplay.percentage(value)).font(.system(.largeTitle, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
                    Spacer(minLength: 2)
                    DashboardGauge(percent: value)
                }
            }.frame(minHeight: 165)
        }
    }
    private var temperature: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CPU").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(fahrenheit ? "°F" : "°C") { fahrenheit.toggle() }.font(.caption).accessibilityLabel("Change temperature unit")
                }
                Text("Temperature").font(.subheadline.weight(.semibold))
                Spacer(minLength: 20)
                if cpuTemperature == nil { Text("Sensor unavailable").font(.caption).foregroundStyle(.secondary) }
                Text(DashboardDisplay.temperature(cpuTemperature, fahrenheit: fahrenheit))
                    .font(.system(size: 54, weight: .light, design: .rounded)).foregroundStyle(.mint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(minHeight: 165)
        }
    }
    private func rateRow(_ title: String, rate: Double?, symbol: String) -> some View {
        VStack(spacing: 7) {
            HStack {
                Image(systemName: symbol).foregroundStyle(.mint)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(DashboardDisplay.rate(rate)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
            }.font(.caption)
        }
    }
    private var networking: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Network").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(telemetry.live?.metrics.network ?? []) { item in
                            Button { selectedNetwork = item.name; UserDefaults.standard.set(item.name, forKey: networkKey) } label: {
                                if network?.name == item.name { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Choose network interface")
                }
                Text(network?.name ?? "No reading").font(.subheadline.weight(.semibold))
                Spacer(minLength: 10)
                rateRow("Sent", rate: network?.txSec, symbol: "arrow.up")
                rateRow("Received", rate: network?.rxSec, symbol: "arrow.down")
                if let value = DashboardDisplay.percent(network?.utilizationPercent) {
                    ProgressView(value: value, total: 100).tint(.mint)
                    Text("\(Int(value))% link utilization").font(.caption2).foregroundStyle(.secondary)
                } else { Text("Interface traffic · bytes/sec").font(.caption2).foregroundStyle(.secondary) }
            }.frame(minHeight: 165)
        }
    }
    private func gpuCard(_ gpu: DashboardGPU) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("GPU").font(.subheadline).foregroundStyle(.secondary)
                Text(gpu.name).font(.headline)
                HStack {
                    Text(DashboardDisplay.temperature(gpu.temperature, fahrenheit: fahrenheit) + (gpu.temperature == nil ? "" : fahrenheit ? "F" : "C")).foregroundStyle(.mint)
                    Spacer()
                    if let power = gpu.power { Text("\(power, specifier: "%.1f") W").foregroundStyle(.secondary) }
                }.font(.subheadline)
                HStack(alignment: .bottom) {
                    Text(DashboardDisplay.percentage(gpu.utilization)).font(.system(.largeTitle, design: .rounded))
                    Spacer()
                    DashboardGauge(percent: gpu.utilization)
                }
                if let value = DashboardDisplay.percent(gpu.utilization) { ProgressView(value: value, total: 100).tint(.mint).accessibilityLabel("GPU load") }
                HStack {
                    Text("VRAM \(DashboardDisplay.percentage(gpu.memory))")
                    Spacer()
                    Text("Encode \(DashboardDisplay.percentage(gpu.encoder))")
                    Text("Decode \(DashboardDisplay.percentage(gpu.decoder))")
                }.font(.caption).foregroundStyle(.secondary)
                if let date = telemetry.gpuUpdated { Text("GPU Statistics · " + date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary) }
                if gpu.unavailable { Text("GPU readings unavailable while assigned to a VM or blocked by the driver.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func storageCard(title: String, subtitle: String, free: Double?, used: Double?, total: Double?, fraction: Double?, status: String? = nil) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline)
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let status { Text(status.replacingOccurrences(of: "DISK_", with: "").replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(status == "DISK_OK" ? .mint : .secondary) }
                }
                StorageDots(fraction: fraction)
                Text("Available").font(.caption).foregroundStyle(.secondary)
                Text(DashboardDisplay.bytes(free)).font(.system(.largeTitle, design: .rounded)).minimumScaleFactor(0.65).lineLimit(1)
                Text("\(DashboardDisplay.bytes(used)) used / \(DashboardDisplay.bytes(total)) total").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func diskCard(_ disk: DashboardStorage.Disk) -> some View {
        storageCard(title: disk.name ?? "Storage", subtitle: [disk.fsType, disk.temp.map { "\($0)°C" }].compactMap { $0 }.joined(separator: " · "), free: disk.fsFree?.value.map { $0 * 1024 }, used: disk.fsUsed?.value.map { $0 * 1024 }, total: disk.fsSize?.value.map { $0 * 1024 }, fraction: disk.fraction, status: disk.status)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        Image("BrandMark").resizable().scaledToFit().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 17))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.demo ? "Demo server" : store.selected?.name ?? "Your server").font(.title2.bold())
                            Text(store.demo ? "Sample data" : "Unraid " + (store.overview?.info.os.release ?? "")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let server = store.selected { NavigationLink { ServerAlertsView(server: server) } label: { Image(systemName: "bell") }.accessibilityLabel("Server alerts") }
                    }
                    if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    if let date = telemetry.updated ?? store.lastUpdated {
                        Text("Updated \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.overview != nil {
                        Text("Status").font(.title2.bold())
                        LazyVGrid(columns: columns, spacing: 14) {
                            usage("CPU", detail: store.overview?.info.cpu.brand ?? "Processor", value: cpu, footnote: telemetry.packages?.power.map { String(format: "%.1f W", $0) })
                            temperature
                            usage("RAM", detail: DashboardDisplay.memory(telemetry.live?.metrics.memory?.total?.value), value: memory, footnote: telemetry.live?.metrics.memory?.used?.value.map { DashboardDisplay.memory($0) + " used" })
                            networking
                        }
                        ForEach(telemetry.gpus) { gpuCard($0) }
                        if telemetry.gpus.isEmpty {
                            DashboardCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("GPU", systemImage: "display").font(.headline)
                                    Text(telemetry.gpuMessage ?? (store.demo ? "GPU statistics appear when connected to a supported server." : "Loading GPU statistics…")).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Storage").font(.title2.bold()).padding(.top, 4)
                        if let array = store.overview?.array {
                            let size = array.capacity.kilobytes
                            storageCard(title: "Array", subtitle: array.state.capitalized, free: Double(size.free).map { $0 * 1024 }, used: Double(size.used).map { $0 * 1024 }, total: Double(size.total).map { $0 * 1024 }, fraction: Double(size.total).flatMap { $0 > 0 ? size.fraction : nil })
                        }
                        if let storage = telemetry.storage {
                            if !storage.array.caches.isEmpty { Text("Pools & cache devices").font(.headline).foregroundStyle(.secondary) }
                            ForEach(storage.array.caches) { diskCard($0) }
                            if let boot = storage.array.boot { diskCard(boot) }
                            if !storage.array.disks.isEmpty { Text("Array disks").font(.headline).foregroundStyle(.secondary) }
                            ForEach(storage.array.disks) { diskCard($0) }
                        }
                    } else if let server = store.selected {
                        if TailnetPolicy.contains(server.address.host ?? ""), !vpn.running {
                            ProgressView("Connecting to Tailscale…")
                            Text(vpn.status).font(.caption).foregroundStyle(.secondary)
                            NavigationLink("Private connection settings") { TailnetSetupView() }
                        } else if store.loading { ProgressView("Loading your server…") }
                        else { Button("Retry connection") { Task { await refresh() } } }
                    } else { Button("Connect a server") { setup = true }.buttonStyle(.borderedProminent) }
                }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }.background { AsterBackdrop() }.navigationTitle("Server").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(store.loading || telemetry.loading || store.selected == nil || store.demo) }
                .refreshable { await refresh() }
                .sheet(isPresented: $setup) { ConnectionView() }
                .task(id: "\(store.selectedID?.uuidString ?? "none")-\(scenePhase)-\(vpn.running)") {
                    guard scenePhase == .active, let server = store.selected, !store.demo else { return }
                    if TailnetPolicy.contains(server.address.host ?? ""), !vpn.running { return }
                    selectedNetwork = UserDefaults.standard.string(forKey: networkKey) ?? ""
                    while !Task.isCancelled {
                        await telemetry.refresh(server)
                        do { try await Task.sleep(for: .seconds(5)) } catch { break }
                    }
                }
                .onChange(of: store.selectedID) { _, _ in telemetry.reset(store.selected) }
        }
    }
}

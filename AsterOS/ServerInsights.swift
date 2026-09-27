import SwiftUI

struct ServerAlert: Decodable, Identifiable {
    let id: String
    let title: String
    let subject: String
    let description: String
    let importance: String
    let timestamp: String?
}
struct ServerAlertsData: Decodable {
    struct Notifications: Decodable { let list: [ServerAlert] }
    let notifications: Notifications
}
struct ContainerLogLine: Decodable {
    let timestamp: String
    let message: String
}
struct ContainerLogsData: Decodable {
    struct Docker: Decodable {
        struct Logs: Decodable { let lines: [ContainerLogLine] }
        let logs: Logs
    }
    let docker: Docker
}
extension UnraidClient {
    static let alertsQuery = "query AsterAlerts { notifications { list(filter: {type: UNREAD, offset: 0, limit: 100}) { id title subject description importance timestamp } } }"
    static let logsQuery = "query AsterLogs($id: PrefixedID!) { docker { logs(id: $id, tail: 500) { lines { timestamp message } } } }"
    func alerts() async throws -> [ServerAlert] {
        let result: ServerAlertsData = try await query(Self.alertsQuery)
        return Array(result.notifications.list.prefix(100))
    }
    func logs(containerID: String) async throws -> [ContainerLogLine] {
        let result: ContainerLogsData = try await query(Self.logsQuery, variables: ["id": containerID])
        return Array(result.docker.logs.lines.suffix(500))
    }
}

struct ServerAlertsView: View {
    let server: ServerProfile
    @State private var alerts: [ServerAlert] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var updated: Date?
    private func refresh() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await UnraidClient(profile: server, key: CredentialStore.read(server.id)).alerts()
            try Task.checkCancellation()
            alerts = result; loaded = true; error = nil; updated = Date()
        } catch is CancellationError { }
        catch { self.error = "Could not refresh alerts. Check connectivity, notification read permission, and whether your Unraid API supports notifications. Previously loaded alerts may be out of date." }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Unread notifications from Unraid. Checked while this screen is open; background push alerts are not enabled.").foregroundStyle(.secondary)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let updated { Text("Updated \(updated.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if loading && !loaded { ProgressView("Loading alerts…").frame(maxWidth: .infinity) }
                if loaded && alerts.isEmpty { ContentUnavailableView("No unread alerts", systemImage: "bell.badge") }
                ForEach(alerts) { alert in
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(alert.title, systemImage: alert.importance == "INFO" ? "info.circle" : "exclamationmark.triangle")
                                .font(.headline).foregroundStyle(alert.importance == "ALERT" ? .red : alert.importance == "WARNING" ? .orange : .mint)
                            if !alert.subject.isEmpty { Text(alert.subject).font(.subheadline.bold()) }
                            Text(alert.description).textSelection(.enabled)
                            if let time = alert.timestamp { Text(time).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if alerts.count == 100 { Text("Showing up to 100 unread notifications. Your server may have more.").font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }.background { AsterBackdrop() }.navigationTitle("Server alerts")
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading) }
            .refreshable { await refresh() }
            .task { await refresh() }
    }
}

struct ContainerLogsView: View {
    let server: ServerProfile
    let container: Container
    @State private var lines: [ContainerLogLine] = []
    @State private var search = ""
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var updated: Date?
    private var matches: [Int] { lines.indices.filter { search.isEmpty || lines[$0].message.localizedCaseInsensitiveContains(search) || lines[$0].timestamp.localizedCaseInsensitiveContains(search) } }
    private func refresh() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await UnraidClient(profile: server, key: CredentialStore.read(server.id)).logs(containerID: container.id)
            try Task.checkCancellation()
            lines = result; loaded = true; error = nil; updated = Date()
        } catch is CancellationError { }
        catch { self.error = "Could not refresh logs. Check connectivity, Docker read permission, and whether your Unraid API supports container logs. Any displayed lines are from the previous refresh." }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Latest 500 lines • \(container.name)").font(.subheadline).foregroundStyle(.secondary)
                if let updated { Text("Updated \(updated.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                if loading && !loaded { ProgressView("Loading logs…").frame(maxWidth: .infinity) }
                if loaded && matches.isEmpty { ContentUnavailableView(search.isEmpty ? "No log lines" : "No matches", systemImage: "text.magnifyingglass") }
                ForEach(matches, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lines[index].timestamp).font(.caption2).foregroundStyle(.secondary)
                        Text(lines[index].message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }.background { AsterBackdrop() }.navigationTitle("Container logs").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search loaded logs")
            .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading) }
            .refreshable { await refresh() }.task { await refresh() }
    }
}

struct SupportSnapshot {
    let appVersion: String
    let systemVersion: String
    let hasServer: Bool
    let privateConnected: Bool
    let overviewLoaded: Bool
    let appCount: Int
    let refreshFailed: Bool
    let dockerRefreshFailed: Bool
    // No server strings, API errors, paths, logs, or identifiers enter this report.
    var report: String {
        """
        AsterOS support report
        App: \(Self.version(appVersion))
        iOS: \(Self.version(systemVersion))
        Server configured: \(hasServer)
        Private connection running: \(privateConnected)
        Server overview loaded: \(overviewLoaded)
        Loaded containers: \(max(0, appCount))
        Server refresh issue: \(refreshFailed)
        Docker refresh issue: \(dockerRefreshFailed)

        Credentials, server addresses, names, file paths, photo details, terminal output, and container logs are excluded.
        """
    }
    static func version(_ value: String) -> String {
        guard value.count <= 40, !value.isEmpty, value.allSatisfy({ "0123456789.-() ".contains($0) }) else { return "unavailable" }
        return value
    }
}
struct SupportReportView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var vpn: TailnetStore
    private var report: String {
        SupportSnapshot(appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")", systemVersion: UIDevice.current.systemVersion, hasServer: store.selected != nil, privateConnected: vpn.running, overviewLoaded: store.overview != nil, appCount: store.containers.count, refreshFailed: store.error != nil, dockerRefreshFailed: store.dockerError != nil).report
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Review before sharing. Nothing is sent automatically.").foregroundStyle(.secondary)
                Text(report).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                ShareLink(item: report) { Label("Share support report", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }.padding(20)
        }.background { AsterBackdrop() }.navigationTitle("Support report")
    }
}

import SwiftUI

enum ContainerHealth: String {
    case healthy, unhealthy, starting, unreported
}
extension Container {
    var isOnline: Bool { state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "RUNNING" }
    var reportedHealth: ContainerHealth {
        let value = status.lowercased()
        if value.contains("(unhealthy)") { return .unhealthy }
        if value.contains("(healthy)") { return .healthy }
        if value.contains("(health: starting)") { return .starting }
        return .unreported
    }
    var needsAttention: Bool { !isOnline || reportedHealth == .unhealthy || reportedHealth == .starting }
    var healthDescription: String {
        guard isOnline else { return state.isEmpty ? "State unavailable" : state.capitalized }
        switch reportedHealth {
        case .healthy: return "Running · Healthy"
        case .unhealthy: return "Running · Unhealthy"
        case .starting: return "Running · Health check starting"
        case .unreported: return "Running · Health not reported"
        }
    }
}
struct ContainerHealthSummary {
    let containers: [Container]
    var online: Int { containers.filter(\.isOnline).count }
    var healthy: Int { containers.filter { $0.isOnline && $0.reportedHealth == .healthy }.count }
    var attention: [Container] { containers.filter(\.needsAttention).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var unreported: Int { containers.filter { $0.isOnline && $0.reportedHealth == .unreported }.count }
    var title: String {
        if containers.isEmpty { return "No container status yet" }
        if !attention.isEmpty { return "\(attention.count) need attention" }
        if healthy == containers.count { return "All containers running and healthy" }
        return "All containers running"
    }
    var detail: String {
        "\(online) of \(containers.count) running · \(healthy) healthy" +
        (unreported > 0 ? " · \(unreported) health not reported" : "")
    }
}

struct ContainerHealthBanner: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let summary = ContainerHealthSummary(containers: store.containers)
        NavigationLink {
            ContainerHealthView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: store.dockerError != nil ? "wifi.exclamationmark" : summary.attention.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.title2)
                    .foregroundStyle(store.dockerError != nil || !summary.attention.isEmpty ? Color.orange : Color.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.dockerError != nil ? "Container status unavailable" : summary.title).font(.headline)
                    Text(store.dockerError != nil && store.containers.isEmpty ? "Waiting for Docker information" : summary.detail).font(.caption).foregroundStyle(.secondary)
                    Text(store.dockerError != nil ? (store.containers.isEmpty ? "Refresh when the service is available" : "Last reported data · tap to inspect") : "Last reported by Unraid · tap for details")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).asterGlass(radius: 26)
        }.buttonStyle(.plain)
    }
}

struct ContainerHealthView: View {
    @EnvironmentObject var store: AppStore
    @State private var details: Container?
    private func row(_ container: Container) -> some View {
        Button { details = container } label: {
            HStack(spacing: 14) {
                ContainerIcon(container: container, server: store.selected?.address)
                    .scaleEffect(0.6).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(container.name).font(.headline).foregroundStyle(.primary)
                    Text(container.healthDescription).font(.subheadline)
                        .foregroundStyle(container.needsAttention ? Color.orange : Color.secondary)
                    Text(container.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }
    var body: some View {
        let summary = ContainerHealthSummary(containers: store.containers)
        GlassForm {
            if store.demo { Section { Text("Demo containers · Sample data").foregroundStyle(.orange) } }
            if let error = store.dockerError { Section { Text(error).foregroundStyle(.orange) } }
            Section {
                Text(summary.title).font(.headline)
                Text(summary.detail).foregroundStyle(.secondary)
                Text("Running means the container is started. Health comes from Docker health checks; containers without a reported check are not assumed healthy. Stopped containers may have been stopped intentionally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !summary.attention.isEmpty {
                Section("Needs attention") { ForEach(summary.attention) { row($0) } }
            }
            Section("Running containers") {
                ForEach(store.containers.filter { !$0.needsAttention }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { row($0) }
            }
        }
        .navigationTitle("Container status").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await store.refresh() } } label: {
                if store.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }.disabled(store.loading || store.demo).accessibilityLabel("Refresh container status")
        }
        .refreshable { await store.refresh() }
        .sheet(item: $details) { ContainerDetailsView(container: $0) }
    }
}

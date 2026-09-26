import SwiftUI

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var demo = false
    @Published var overview: Overview?
    @Published var metrics: Metrics?
    @Published var containers: [Container] = []
    @Published var error: String?
    @Published var dockerError: String?
    @Published var metricsError: String?
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var operating = false
    private var generation = UUID()
    var selected: ServerProfile? { profiles.first { $0.id == selectedID } }
    init() {
        if let data = UserDefaults.standard.data(forKey: "serverProfiles") {
            do { profiles = try JSONDecoder().decode([ServerProfile].self, from: data) }
            catch { self.error = "Saved connections could not be loaded." }
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedServer"), let id = UUID(uuidString: raw), profiles.contains(where: { $0.id == id }) { selectedID = id }
        else { selectedID = profiles.first?.id }
    }
    private func persist() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(profiles), forKey: "serverProfiles") }
        catch { self.error = "Unable to save connections." }
        UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedServer")
    }
    func select(_ id: UUID?) {
        generation = UUID(); demo = false; selectedID = id
        overview = nil; metrics = nil; containers = []; error = nil; dockerError = nil; metricsError = nil; lastUpdated = nil; loading = false
        persist()
    }
    func showDemo() {
        select(nil); demo = true; overview = .demo; metrics = .demo
        containers = [Container(id: "demo", names: ["Example app"], state: "RUNNING", status: "Sample data")]
    }
    func connect(name: String, address: String, key: String, kind: ConnectionKind) async throws {
        let url = try AddressPolicy.validate(address)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw AppError.message("Enter an API key generated on your Unraid server.") }
        let profile = ServerProfile(name: name.isEmpty ? (url.host ?? "Unraid") : name, address: url, connection: kind)
        let client = UnraidClient(profile: profile, key: secret)
        let result = try await client.overview()
        try CredentialStore.save(secret, for: profile.id)
        profiles.append(profile); select(profile.id); overview = result; lastUpdated = Date()
    }
    func removeSelected() throws {
        guard let id = selectedID else { select(profiles.first?.id); return }
        try DirectFilesStore.forget(serverID: id)
        try CredentialStore.remove(id)
        profiles.removeAll { $0.id == id }; select(profiles.first?.id)
    }
    func addApp(name: String, address: String, containerID: String? = nil) throws {
        let url = try AddressPolicy.validate(address)
        guard let i = profiles.firstIndex(where: { $0.id == selectedID }) else { throw AppError.message("Connect a server before adding an app.") }
        if let containerID { profiles[i].apps.removeAll { $0.containerID == containerID || ($0.containerID == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame) } }
        profiles[i].apps.append(SavedApp(name: name.isEmpty ? (url.host ?? "App") : name, url: url, containerID: containerID)); persist()
    }
    func removeApp(_ id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles[i].apps.removeAll { $0.id == id }; persist()
    }
    func refresh() async {
        guard !demo, let profile = selected, !loading else { return }
        let token = generation
        loading = true
        defer { if token == generation { loading = false } }
        do {
            let client = UnraidClient(profile: profile, key: try CredentialStore.read(profile.id))
            let result = try await client.overview()
            guard token == generation else { return }
            overview = result; error = nil; lastUpdated = Date()
            do {
                let result = try await client.containers()
                guard token == generation else { return }
                containers = result; dockerError = nil
            } catch { if token == generation { containers = []; dockerError = error.localizedDescription } }
            do {
                let result = try await client.metrics()
                guard token == generation else { return }
                metrics = result; metricsError = nil
            } catch { if token == generation { metrics = nil; metricsError = "Live metrics unavailable with this server version or API permissions." } }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    func perform(_ action: ContainerAction, container: Container) async {
        guard let profile = selected, !demo, !operating else { return }
        let token = generation; operating = true
        defer { operating = false }
        do {
            let client = UnraidClient(profile: profile, key: try CredentialStore.read(profile.id))
            try await client.perform(action, id: container.id)
            guard token == generation else { return }
            let updated = try await client.containers()
            guard token == generation else { return }
            containers = updated; dockerError = nil
        } catch { if token == generation { dockerError = error.localizedDescription } }
    }
}

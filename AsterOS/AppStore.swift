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
    @Published private(set) var showConnectionProgress = false
    @Published var operating = false
    @Published private(set) var preferencesRevision = 0
    @Published private(set) var connectionStage: String?
    @Published private(set) var stageStarted: Date?
    private var photoBackups: [UUID: PhotoBackupStore] = [:]
    func photoBackup(for profile: ServerProfile) -> PhotoBackupStore {
        if let store = photoBackups[profile.id] { return store }
        let store = PhotoBackupStore(serverID: profile.id, address: profile.address, knownServerIDs: profiles.map(\.id), defaults: defaults)
        photoBackups[profile.id] = store
        return store
    }
    func photoBackupSceneChanged(_ phase: ScenePhase) {
        for backup in photoBackups.values { backup.sceneChanged(phase) }
    }
    private func pausePhotoBackups() { for backup in photoBackups.values { backup.pause() } }
    private var previousServerID: UUID?
    private var generation = UUID()
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    private func stage(_ title: String) { connectionStage = title; stageStarted = Date() }
    var selected: ServerProfile? { profiles.first { $0.id == selectedID } }
    private let defaults: UserDefaults
    private let makeClient: (ServerProfile) throws -> any ServerAPI
    init(defaults: UserDefaults = .standard, client: ((ServerProfile) throws -> any ServerAPI)? = nil) {
        self.defaults = defaults
        self.makeClient = client ?? { profile in UnraidClient(profile: profile, key: try CredentialStore.read(profile.id)) }
        if let data = defaults.data(forKey: "serverProfiles") {
            do { profiles = try JSONDecoder().decode([ServerProfile].self, from: data) }
            catch { if defaults.data(forKey: "serverProfiles-recovery") == nil { defaults.set(data, forKey: "serverProfiles-recovery") }; self.error = "Saved connections could not be loaded. A recovery copy has been kept." }
        }
        if let raw = defaults.string(forKey: "selectedServer"), let id = UUID(uuidString: raw), profiles.contains(where: { $0.id == id }) { selectedID = id }
        else { selectedID = profiles.first?.id }
    }
    private func persist() {
        do { defaults.set(try JSONEncoder().encode(profiles), forKey: "serverProfiles") }
        catch { self.error = "Unable to save connections." }
        defaults.set(selectedID?.uuidString, forKey: "selectedServer")
    }
    func select(_ id: UUID?) {
        if id != selectedID { pausePhotoBackups() }
        generation = UUID(); demo = false; selectedID = id; connectionStage = nil; stageStarted = nil
        overview = nil; metrics = nil; containers = []; error = nil; dockerError = nil; metricsError = nil; lastUpdated = nil; loading = false
        persist()
    }
    func showDemo() {
        guard !demo, !operating else { return }
        pausePhotoBackups()
        previousServerID = selectedID
        generation = UUID(); selectedID = nil; demo = true
        overview = .demo; metrics = .demo; containers = []
        error = nil; dockerError = nil; metricsError = nil; lastUpdated = nil
        loading = false; connectionStage = nil; stageStarted = nil
        // Never persist demo selection over the user's saved server.
    }
    func exitDemo() { select(previousServerID ?? profiles.first?.id); previousServerID = nil }
    func connect(name: String, address: String, key: String, kind: ConnectionKind, profileID: UUID = UUID()) async throws {
        guard !profiles.contains(where: { $0.id == profileID }) else { throw AppError.message("This connection is already saved.") }
        let url = try AddressPolicy.validate(address)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw AppError.message("Enter an API key generated on your Unraid server.") }
        let profile = ServerProfile(id: profileID, name: name.isEmpty ? (url.host ?? "Unraid") : name, address: url, connection: kind)
        let client = UnraidClient(profile: profile, key: secret)
        let result = try await client.overview()
        try CredentialStore.save(secret, for: profile.id)
        profiles.append(profile); select(profile.id); overview = result; lastUpdated = Date()
    }
    func renewAuthorization(serverID: UUID, key: String) async throws {
        guard let profile = profiles.first(where: { $0.id == serverID }) else { throw AppError.message("This server is no longer saved.") }
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw AppError.message("A server credential is required.") }
        let result = try await UnraidClient(profile: profile, key: secret).overview()
        guard profiles.contains(where: { $0.id == serverID && $0.address == profile.address }) else { throw AppError.message("The saved connection changed. Please try again.") }
        try CredentialStore.save(secret, for: serverID)
        // Keep the profile ID, app organization, share account, and backup destination.
        if selectedID == serverID { select(serverID); overview = result; lastUpdated = Date() }
    }
    func removeSelected() throws {
        guard let id = selectedID else { select(profiles.first?.id); return }
        photoBackups[id]?.pause(); photoBackups.removeValue(forKey: id)
        try DirectFilesStore.forget(serverID: id, address: selected?.address)
        try CredentialStore.remove(id)
        TerminalSessions.forget(id)
        try CatalogSession.forget(serverID: id)
        profiles.removeAll { $0.id == id }; select(profiles.first?.id)
    }
    func addApp(name: String, address: String, containerID: String? = nil) throws {
        let url = try AddressPolicy.validate(address)
        guard let i = profiles.firstIndex(where: { $0.id == selectedID }) else { throw AppError.message("Connect a server before adding an app.") }
        if let containerID { profiles[i].apps.removeAll { $0.containerID == containerID || ($0.containerID == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame) } }
        profiles[i].apps.append(SavedApp(name: name.isEmpty ? (url.host ?? "App") : name, url: url, containerID: containerID)); persist()
    }
    func usePrivateAddress(for app: SavedApp) throws -> URL {
        guard let i = profiles.firstIndex(where: { $0.id == selectedID }),
              let url = PrivateAppAddress.replacingHost(of: app.url, with: profiles[i].address),
              let host = url.host, TailnetStore.shared.isKnownPeer(host) else {
            throw AppError.message("Connect AsterOS to Tailscale and select your server’s Tailscale address first.")
        }
        var saved = app; saved.url = url
        if let index = profiles[i].apps.firstIndex(where: { $0.id == app.id || (app.containerID != nil && $0.containerID == app.containerID) }) {
            saved.id = profiles[i].apps[index].id
            profiles[i].apps[index] = saved
        } else { profiles[i].apps.append(saved) }
        persist()
        return url
    }
    func importPreferences(_ archive: PreferencesArchive, serverID: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == serverID }), selectedID == serverID else { throw AppError.message("The selected server changed.") }
        guard photoBackups[serverID]?.busy != true else { throw AppError.message("Pause photo backup before restoring preferences.") }
        try archive.apply(to: profiles[index])
        photoBackups.removeValue(forKey: serverID)
        profiles[index].apps = archive.apps; persist(); preferencesRevision += 1
    }
    func removeApp(_ id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles[i].apps.removeAll { $0.id == id }; persist()
    }
    func refresh() async {
        guard !demo, let profile = selected, !loading, !operating else { return }
        let token = generation
        showConnectionProgress = lastUpdated == nil || error != nil || Date().timeIntervalSince(lastUpdated ?? .distantPast) > 30
        loading = true; stage("Connecting to server")
        defer { if token == generation { loading = false; showConnectionProgress = false; connectionStage = nil; stageStarted = nil } }
        do {
            let client = try makeClient(profile)
            let result = try await client.overview()
            try Task.checkCancellation()
            guard token == generation else { return }
            overview = result; error = nil; lastUpdated = Date()
            stage("Loading apps")
            do {
                let result = try await client.containers()
                try Task.checkCancellation()
                guard token == generation else { return }
                containers = result; dockerError = nil
            } catch { if Self.isCancellation(error) || Task.isCancelled { return }; if token == generation { dockerError = "Could not refresh apps. The last loaded list is shown and may be out of date. " + error.localizedDescription } }
            guard token == generation else { return }
            stage("Loading live metrics")
            do {
                let result = try await client.metrics()
                try Task.checkCancellation()
                guard token == generation else { return }
                metrics = result; metricsError = nil
            } catch { if Self.isCancellation(error) || Task.isCancelled { return }; if token == generation { metrics = nil; metricsError = "Live metrics unavailable with this server version or API permissions." } }
        } catch {
            guard !Self.isCancellation(error), !Task.isCancelled else { return }
            if token == generation {
                self.error = error.localizedDescription
                dockerError = "Server connection unavailable. The last app list may be out of date. Refresh before changing containers."
                metrics = nil; metricsError = "Waiting for a new reading."
            }
        }
    }
    func removeContainer(_ container: Container, from serverID: UUID) async throws {
        guard let profile = selected, profile.id == serverID, !demo else { throw AppError.message("The selected server changed. Open this app's details again before removing it.") }
        guard !operating else { throw AppError.message("Wait for the current container operation to finish.") }
        let token = generation; operating = true
        defer { operating = false }
        let client = try makeClient(profile)
        // Never retry a removal automatically if the connection drops after it was sent.
        try await client.removeContainer(id: container.id)
        guard token == generation else { return }
        loading = false
        generation = UUID() // Invalidate a list refresh that started before removal.
        let refreshToken = generation
        containers.removeAll { $0.id == container.id }
        if let index = profiles.firstIndex(where: { $0.id == serverID }) {
            profiles[index].apps.removeAll { $0.containerID == container.id }
            persist()
        }
        dockerError = nil
        do {
            let updated = try await client.containers()
            if refreshToken == generation { containers = updated }
        } catch {
            if refreshToken == generation { dockerError = "Container removed. The app list could not refresh; pull down to refresh it." }
        }
    }
    func perform(_ action: ContainerAction, container: Container) async {
        guard let profile = selected, !demo, !operating, dockerError == nil else { return }
        let token = generation; operating = true
        defer { operating = false }
        do {
            let client = try makeClient(profile)
            try await client.perform(action, id: container.id)
            guard token == generation else { return }
            generation = UUID(); loading = false
            let refreshToken = generation
            do {
                let updated = try await client.containers()
                guard refreshToken == generation else { return }
                containers = updated; dockerError = nil
            } catch {
                if refreshToken == generation { dockerError = "Unraid confirmed the action, but the app list could not refresh. Refresh to check the current state." }
            }
        } catch { if token == generation { dockerError = "The action could not be confirmed. Refresh and check the container before trying again. " + error.localizedDescription } }
    }
}

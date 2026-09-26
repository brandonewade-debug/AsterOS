import SwiftUI
import NetworkExtension

@MainActor final class VPNStore: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var endpoint = ""
    @Published var error: String?
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "vpnConnectOnLaunch") }
    }
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var attemptedLaunch = false
    static let providerID = "com.asterlinelabs.asteros.tunnel"
    static var supported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
    var active: Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(status) }
    var statusText: String {
        guard Self.supported else { return "Requires an iPhone or iPad" }
        switch status {
        case .connected: return "Tunnel active"
        case .connecting: return "Connecting…"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Disconnected"
        default: return "Not configured"
        }
    }
    init() {
        automatic = UserDefaults.standard.bool(forKey: "vpnConnectOnLaunch")
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func updateStatus() { status = manager?.connection.status ?? .invalid }
    func launch() async {
        guard !attemptedLaunch else { return }
        attemptedLaunch = true
        await load()
        if automatic && configured && !active { connect() }
    }
    func load() async {
        guard Self.supported, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID }
            configured = manager != nil
            endpoint = manager?.protocolConfiguration?.serverAddress ?? ""
            updateStatus(); error = nil
        } catch { self.error = "Unable to load AsterOS VPN settings. This build needs valid Network Extension signing." }
    }
    func install(_ text: String) async throws {
        guard Self.supported else { throw AppError.message("VPN installation requires a signed build on a physical iPhone or iPad.") }
        guard !busy, !configured else { throw AppError.message("Remove the existing AsterOS VPN profile before importing another.") }
        let parsed = try VPNConfiguration.parse(text)
        busy = true; defer { busy = false }
        let reference = try VPNKeychain.save(text)
        let candidate = NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Self.providerID
        configuration.serverAddress = parsed.peers[0].endpoint?.stringRepresentation
        configuration.passwordReference = reference
        configuration.disconnectOnSleep = false
        candidate.protocolConfiguration = configuration
        candidate.localizedDescription = "AsterOS"
        candidate.isEnabled = true
        candidate.isOnDemandEnabled = false
        do { try await candidate.saveToPreferences() }
        catch {
            try? VPNKeychain.remove(reference)
            throw AppError.message("The VPN profile was not saved. Allow the iOS VPN prompt and check this build’s Network Extension signing.")
        }
        // Once preferences are saved the credential must remain available, even if reload fails.
        manager = candidate; configured = true; automatic = true
        endpoint = configuration.serverAddress ?? ""; error = nil
        do { try await candidate.loadFromPreferences(); updateStatus() }
        catch { throw AppError.message("VPN profile saved, but settings could not be refreshed. Reopen AsterOS before connecting.") }
    }
    func connect() {
        guard Self.supported, let manager, !busy, !active else { return }
        guard manager.isEnabled else { error = "Enable the AsterOS VPN configuration in iOS Settings, then reopen AsterOS."; return }
        do {
            try manager.connection.startVPNTunnel()
            updateStatus(); error = nil
        } catch { self.error = "Unable to start AsterOS VPN. Check the saved profile and this build’s Network Extension signing." }
    }
    func disconnect() {
        guard !busy else { return }
        manager?.connection.stopVPNTunnel()
        updateStatus()
        // No automatic retry in this process after an explicit disconnect.
    }
    func remove() async {
        guard let manager, !busy, !active else { return }
        busy = true; defer { busy = false }
        let reference = manager.protocolConfiguration?.passwordReference
        do {
            try await manager.removeFromPreferences()
            self.manager = nil; configured = false; endpoint = ""; automatic = false; updateStatus()
            if let reference { try VPNKeychain.remove(reference) }
            error = nil
        } catch { self.error = "Unable to finish removing the VPN profile or its saved credential. Retry from Settings." }
    }
}

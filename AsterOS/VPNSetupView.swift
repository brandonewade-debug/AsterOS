import SwiftUI
import UniformTypeIdentifiers

struct VPNSetupView: View {
    @EnvironmentObject private var vpn: VPNStore
    @State private var importing = false
    @State private var pending: String?
    @State private var pendingEndpoint = ""
    @State private var pendingRoutes = ""
    @State private var confirming = false
    @State private var removing = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Label(vpn.statusText, systemImage: "network.badge.shield.half.filled").font(.headline)
                if !vpn.endpoint.isEmpty { Text(vpn.endpoint).font(.caption).foregroundStyle(.secondary) }
                Text("Connect to your Unraid server with WireGuard built into AsterOS. No separate VPN app or companion container is needed.")
                if !VPNStore.supported { Text("The simulator can preview setup but cannot run this VPN. A signed physical-device build is required.").foregroundStyle(.orange) }
            }
            if vpn.configured {
                Section("Connection") {
                    Toggle("Connect when AsterOS launches", isOn: $vpn.automatic)
                    if vpn.active {
                        Button("Disconnect", role: .destructive) { vpn.disconnect() }.disabled(vpn.status == .disconnecting)
                    } else { Button("Connect") { vpn.connect() } }
                    Text("The VPN stays connected when you switch apps or lock your phone. Use Disconnect when you are finished; swiping AsterOS away does not reliably stop the tunnel.").font(.caption).foregroundStyle(.secondary)
                    Text("Tunnel active means the VPN is running. Server reachability still depends on the peer configuration and network.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Remove VPN profile", role: .destructive) { removing = true }.disabled(vpn.active)
                }
            } else {
                Section("Set up once") {
                    Text("In Unraid → Settings → VPN Manager, create a dedicated WireGuard peer for this device with remote access to your server or LAN. Export its .conf file, then import it here.")
                    Button("Import WireGuard configuration", systemImage: "square.and.arrow.down") { importing = true }
                    Text("iOS will ask you to allow the VPN configuration. The private key is stored in Keychain. The exported file also contains a private key; keep it private.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Routing") {
                Text("This preview accepts one peer and private server/LAN routes. Export a split-tunnel profile without a DNS override. It does not replace your normal internet connection.")
                Text("The server’s WireGuard UDP endpoint must be reachable from outside your network. This is a different connection from Tailscale and requires its own server setup.")
                Text("Starting this VPN may replace another active VPN on your device. Other apps can use the private routes while it is connected.").font(.caption).foregroundStyle(.secondary)
            }
            if vpn.busy { ProgressView("Saving VPN settings…") }
            if let text = error ?? vpn.error { Text(text).foregroundStyle(.orange) }
        }
        .navigationTitle("AsterOS VPN")
        .disabled(vpn.busy)
        .task { await vpn.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let data = try file.read(upToCount: 65537) ?? Data()
                guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw VPNConfigurationError.invalid }
                let parsed = try VPNConfiguration.parse(text)
                pending = text
                pendingEndpoint = parsed.peers[0].endpoint?.stringRepresentation ?? ""
                pendingRoutes = parsed.peers[0].allowedIPs.map(\.stringRepresentation).joined(separator: ", ")
                error = nil; confirming = true
            } catch { self.error = "Unable to import this file. \((error as? VPNConfigurationError)?.localizedDescription ?? "Choose a readable WireGuard .conf file.")" }
        }
        .confirmationDialog("Add AsterOS VPN?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Allow VPN setup") {
                guard let text = pending else { return }
                pending = nil
                Task {
                    do { try await vpn.install(text); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }.disabled(!VPNStore.supported)
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("Server: \(pendingEndpoint)\nPrivate routes: \(pendingRoutes)\nAutomatic connection on future launches will be enabled.") }
        .onChange(of: confirming) { _, shown in if !shown { pending = nil } }
        .confirmationDialog("Remove AsterOS VPN and its private key?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await vpn.remove() } }
        }
    }
}

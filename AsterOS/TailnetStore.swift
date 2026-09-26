import SwiftUI
import Network
import AuthenticationServices
import TailscaleKit

struct TailnetPeer: Decodable, Identifiable {
    let peerID: String?
    enum CodingKeys: String, CodingKey { case peerID = "ID", HostName, DNSName, Online }
    let HostName: String?
    let DNSName: String?
    let Online: Bool?
    var id: String { peerID ?? DNSName ?? HostName ?? "" }
    var host: String { (DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
}
private struct TailnetStatus: Decodable {
    let BackendState: String?
    let AuthURL: String?
    let Peer: [String: TailnetPeer]?
}

enum TailnetPolicy {
    // Never use an empty match list: that would proxy the entire internet.
    static let domains = ["ts.net", "100.64.0.0/10", "fd7a:115c:a1e0::/48"]
    static func contains(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.hasSuffix(".ts.net") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value & 0xffc00000 == 0x64400000
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
        }
        return false
    }
    static func loginURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              url.host == "login.tailscale.com", (url.port == nil || url.port == 443), url.user == nil, url.password == nil else { return nil }
        return url
    }
}
private struct SilentTailnetLogger: LogSink {
    var logFileHandle: Int32? { -1 }
    func log(_ message: String) {}
}

@MainActor final class TailnetStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = TailnetStore()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "embeddedTailnetEnabled")
    @Published private(set) var status = "Not connected"
    @Published private(set) var running = false
    @Published private(set) var peers: [TailnetPeer] = []
    @Published private(set) var revision = 0
    @Published var error: String?
    private var node: TailscaleNode?
    private var loopback: TailscaleNode.LoopbackConfig?
    private var launchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?
    private var authURL: URL?
    private var wantsSignIn = false
    private var recovering = false

    func launch() async {
        guard enabled else { return }
        if let launchTask { await launchTask.value; return }
        guard node == nil else { return }
        let task = Task { await startNode() }
        launchTask = task
        await task.value
        launchTask = nil
    }
    private func startNode() async {
        status = "Connecting…"; error = nil
        do {
            var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Tailnet", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let config = Configuration(hostName: "asteros-" + deviceSuffix(), path: directory.path, authKey: nil, controlURL: kDefaultControlURL, ephemeral: false)
            let instance = try await Task.detached { try TailscaleNode(config: config, logger: SilentTailnetLogger()) }.value
            node = instance
            loopback = try await instance.loopback()
            revision += 1
            // Start already initiates interactive login; up() would wait indefinitely for approval.
            await refreshStatus()
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await self?.refreshStatus()
                }
            }
        } catch {
            status = "Connection unavailable"
            self.error = "Could not start the private connection. Tap Retry."
            if let node { try? await node.close() }
            node = nil; loopback = nil; running = false
        }
    }
    private func deviceSuffix() -> String {
        if let value = UserDefaults.standard.string(forKey: "tailnetDeviceSuffix") { return value }
        let value = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(value, forKey: "tailnetDeviceSuffix")
        return value
    }
    func signIn() async {
        enabled = true; UserDefaults.standard.set(true, forKey: "embeddedTailnetEnabled")
        wantsSignIn = true; error = nil
        await launch()
        if let node, !running {
            do { try await LocalAPIClient(localNode: node, logger: nil).startLoginInteractive() }
            catch { self.error = "Could not open Tailscale sign-in. Retry the connection." }
        }
        await refreshStatus()
    }
    private func refreshStatus() async {
        guard let instance = node else { return }
        do {
            let value = try JSONDecoder().decode(TailnetStatus.self, from: try await instance.statusJSON())
            guard node === instance else { return }
            running = value.BackendState == "Running"
            switch value.BackendState {
            case "Running": status = "Connected privately"; error = nil
            case "NeedsLogin": status = "Sign in to Tailscale"
            case "NeedsMachineAuth": status = "Waiting for device approval"
            case "Stopped": status = "Connection stopped"
            default: status = "Connecting…"
            }
            peers = (value.Peer ?? [:]).values.filter { !$0.host.isEmpty }.sorted { $0.host < $1.host }
            authURL = TailnetPolicy.loginURL(value.AuthURL)
            if running { wantsSignIn = false; authSession?.cancel(); authSession = nil }
            else if wantsSignIn, authSession == nil, let authURL { showSignIn(authURL) }
        } catch {
            self.error = "Could not read the private connection status. Retry when you are online."
        }
    }
    private func showSignIn(_ url: URL) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ipnauth", completionHandler: Self.authCompletion(self))
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        authSession = session
        if !session.start() { authSession = nil; wantsSignIn = false; error = "Sign-in could not open. Tap Sign in to try again." }
    }
    nonisolated private static func authCompletion(_ store: TailnetStore) -> @Sendable (URL?, Error?) -> Void {
        { [weak store] _, _ in Task { @MainActor in store?.authSession = nil; store?.wantsSignIn = false; await store?.refreshStatus() } }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    // Do not stop on background/inactive. iOS may suspend networking; validate the listener on return.
    func foreground() async {
        await launch()
        guard let node, let loopback, !recovering else { return }
        recovering = true
        defer { recovering = false }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
            config.proxyConfigurations = [makeProxy(loopback, scoped: false)]
            let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "http://\(loopback.address)/localapi/v0/status")!)
            request.setValue("Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.cannotConnectToHost) }
            await refreshStatus()
        } catch {
            // Close before reusing the persisted identity/state directory. Never replay a mutation.
            pollTask?.cancel(); pollTask = nil
            try? await node.close()
            self.node = nil; self.loopback = nil; running = false; revision += 1
            await launch()
        }
    }
    func retry() async { await foreground() }
    func signOut() async {
        guard let node, let loopback else { error = "Retry the connection before signing out."; return }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 10
            config.proxyConfigurations = [makeProxy(loopback, scoped: false)]
            let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "http://\(loopback.address)/localapi/v0/logout")!)
            request.httpMethod = "POST"
            request.setValue("Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
            let (_, response) = try await session.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else { throw URLError(.badServerResponse) }
            pollTask?.cancel(); pollTask = nil; authSession?.cancel(); authSession = nil
            wantsSignIn = false
            try await node.close()
            self.node = nil; self.loopback = nil; running = false; peers = []
            enabled = false; UserDefaults.standard.set(false, forKey: "embeddedTailnetEnabled")
            status = "Signed out"; error = nil; revision += 1
        } catch { self.error = "Sign-out could not finish. Retry the connection and try again." }
    }
    private func makeProxy(_ config: TailscaleNode.LoopbackConfig, scoped: Bool) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(config.ip!), port: .init(rawValue: UInt16(config.port!))!))
        proxy.applyCredential(username: "tsnet", password: config.proxyCredential)
        if scoped { proxy.matchDomains = TailnetPolicy.domains }
        return proxy
    }
    var proxies: [ProxyConfiguration] {
        guard enabled else { return [] }
        if let loopback { return [makeProxy(loopback, scoped: true)] }
        // Fail closed while starting; never silently send private requests over the public route.
        var blocked = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: 1))
        blocked.matchDomains = TailnetPolicy.domains
        return [blocked]
    }
    func prepare(for host: String?) async throws -> [ProxyConfiguration] {
        guard enabled else { return [] }
        await launch()
        guard let host, TailnetPolicy.contains(host) else { return proxies }
        guard running else { throw AppError.message("Open Private connection and finish Tailscale sign-in or device approval first.") }
        return proxies
    }
    func smbParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let privacy = NWParameters.PrivacyContext(description: "AsterOS private shares")
        privacy.proxyConfigurations = proxies
        parameters.setPrivacyContext(privacy)
        return parameters
    }
}

struct TailnetSetupView: View {
    @ObservedObject private var tailnet = TailnetStore.shared
    @AppStorage("connectionDraftAddress") private var address = ""
    @AppStorage("connectionDraftName") private var name = ""
    @State private var port = "443"
    @State private var chosen: String?
    @State private var confirmSignOut = false
    var body: some View {
        Form {
            Section {
                Label("Your server, privately", systemImage: "network.badge.shield.half.filled").font(.title2.bold())
                Text("Sign in to your existing Tailscale network. AsterOS connects itself—no separate VPN app or companion is needed.")
                LabeledContent("Status", value: tailnet.status)
                if !tailnet.running { Button("Sign in to Tailscale") { Task { await tailnet.signIn() } } }
                if tailnet.running { Button("Sign out of Tailscale", role: .destructive) { confirmSignOut = true } }
                Button("Retry connection") { Task { await tailnet.retry() } }
                if let error = tailnet.error { Text(error).foregroundStyle(.orange) }
            }
            if tailnet.running {
                Section("Choose your Unraid server") {
                    TextField("Unraid HTTPS port", text: $port).keyboardType(.numberPad)
                    ForEach(tailnet.peers) { peer in
                        Button {
                            guard let number = Int(port), (1...65535).contains(number) else { tailnet.error = "Enter a port between 1 and 65535."; return }
                            var parts = URLComponents(); parts.scheme = "https"; parts.host = peer.host
                            parts.port = number == 443 ? nil : number
                            guard let url = parts.url else { return }
                            address = url.absoluteString; name = peer.HostName ?? "Unraid"; chosen = peer.host
                        } label: {
                            VStack(alignment: .leading) {
                                Text(peer.HostName ?? peer.host)
                                Text(peer.host).font(.caption).foregroundStyle(.secondary)
                                if peer.Online == false { Text("Currently offline").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    if chosen != nil { Text("Server selected. Go back and tap Sign in to Unraid.").foregroundStyle(.mint) }
                    if tailnet.peers.isEmpty { Text("No visible devices yet. Check that your server is in this tailnet and its access rules allow this device.") }
                }
            }
            Section {
                Text("AsterOS reconnects when opened. Switching apps does not deliberately disconnect it. iOS can pause networking in the background; closing AsterOS ends its app-owned connection. Other apps do not use this connection.")
                Text("This preview routes Tailscale addresses and full .ts.net names. Use a trusted HTTPS certificate on your Unraid server. LAN subnet routes and exit nodes are not enabled.")
            }.font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Private connection")
        .task { await tailnet.launch() }
        .confirmationDialog("Sign out of this AsterOS connection?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await tailnet.signOut() } }
        } message: { Text("Private server access in AsterOS will stop. Other devices on your tailnet are unaffected.") }
    }
}

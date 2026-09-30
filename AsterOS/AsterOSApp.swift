import SwiftUI

@main struct AsterOSApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var lock = AppLockStore()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vpn = TailnetStore.shared
    init() {
        do { try PrivateTemporaryFiles.removeAbandoned(); UserDefaults.standard.removeObject(forKey: "temporaryCleanupFailed") }
        catch { UserDefaults.standard.set(true, forKey: "temporaryCleanupFailed") }
    }
    var body: some Scene { WindowGroup { RootView().environmentObject(store).environmentObject(vpn).environmentObject(lock).tint(.mint).opacity(lock.locked || lock.shield ? 0 : 1).accessibilityHidden(lock.locked || lock.shield).background(AppSecurityWindow(lock: lock)).onChange(of: scenePhase, initial: true) { _, phase in lock.sceneChanged(phase); store.photoBackupSceneChanged(phase) } } }
}
enum DockTheme {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.08)
    static let card = Color(red: 0.095, green: 0.11, blue: 0.13)
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .asterGlass()
    }
}
enum AppTab: String { case server, files, photos, apps, settings }
struct RootView: View {
    @SceneStorage("selectedAppTab") private var selectedTab = AppTab.server
    @EnvironmentObject var vpn: TailnetStore
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup = false
    @StateObject private var sample = DemoWorkspace()
    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Server", systemImage: "server.rack", value: AppTab.server) { DashboardView() }
            Tab("Files", systemImage: "folder", value: AppTab.files) { if store.demo { DemoFilesView() } else { FilesView() } }
            Tab("Photos", systemImage: "photo", value: AppTab.photos) { if store.demo { DemoPhotosView() } else { PhotosView() } }
            Tab("Apps", systemImage: "square.grid.2x2", value: AppTab.apps) { if store.demo { DemoAppsView() } else { AppsView() } }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { if store.demo { DemoSettingsView() } else { SettingsView() } }
        }
        .environmentObject(sample)
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.demo {
                HStack {
                    Label("Demo · Sample data", systemImage: "sparkles").font(.caption.bold())
                    Spacer()
                    Button("Exit demo") { store.exitDemo(); if store.selected == nil { setup = true } }.font(.caption.bold())
                }.padding(.horizontal, 20).padding(.vertical, 8).background(.ultraThinMaterial)
            } else { ConnectionProgressView() }
        }
        .onChange(of: store.demo) { _, demo in if demo { sample.reset(); selectedTab = .server } }
        .preferredColorScheme(.dark)
        .task(id: "\(scenePhase)-\(store.demo)") { if scenePhase == .active && !store.demo { await vpn.foreground() } }
        .sheet(isPresented: $setup) { ConnectionView() }
        .onAppear { if store.selected == nil && !store.demo { setup = true } }
        .task(id: "\(store.selectedID?.uuidString ?? "none")-\(scenePhase)-\(vpn.running)-\(store.demo)") {
            guard scenePhase == .active, !store.demo else { return }
            if let server = store.selected, TailnetPolicy.contains(server.address.host ?? ""), !vpn.running { return }
            while !Task.isCancelled {
                // A cancelled previous foreground refresh may still be unwinding.
                // Wait briefly instead of skipping the reconnect for a full poll interval.
                if store.loading || store.operating {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                    continue
                }
                await store.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
}
struct ConnectionView: View {
    var renewing: ServerProfile? = nil
    @State private var prepared = false
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("connectionDraftName") private var name = ""
    @AppStorage("connectionDraftAddress") private var address = ""
    @State private var key = ""
    @State private var kind: ConnectionKind = .custom
    @State private var authorization: UnraidAuthorization?
    @State private var connectionID = UUID()
    @State private var allowDockerManagement = true
    @State private var localHTTPAllowed = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    HStack(spacing: 12) {
                        Image("BrandMark").resizable().scaledToFit().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Your server. Within reach.").font(.title2.bold())
                    }
                    Text("Connect with HTTPS or Tailscale. For a local HTTP server, enter its full http:// private IP address and enable local HTTP below.").foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { TailnetSetupView() } label: { Label("Connect with Tailscale", systemImage: "network.badge.shield.half.filled") }
                }
                Section {
                    TextField("Server name", text: $name).disabled(renewing != nil)
                    Picker("Method", selection: $kind) { ForEach(ConnectionKind.allCases) { Text($0.rawValue).tag($0) } }.disabled(renewing != nil)
                    TextField("https://server.example.com", text: $address).disabled(renewing != nil).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Connection") } footer: {
                    Text("Enter your server address, then sign in below. No API key needs to be copied.")
                }
                if let localURL = URL(string: address), LocalHTTPPolicy.eligible(localURL) {
                    Section {
                        Toggle("Allow HTTP on my local network", isOn: Binding(
                            get: { localHTTPAllowed },
                            set: { value in
                                localHTTPAllowed = value
                                LocalHTTPPolicy.setApproved(value, for: localURL)
                            }))
                        Text("HTTP does not encrypt your password, API key, or server data. Enable only on a network you trust. This choice applies only to this IP address and port, and is remembered on this device.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Manage Docker apps", isOn: $allowDockerManagement)
                    Text(allowDockerManagement ? "Requests Docker create, update, and delete access alongside monitoring. Allows native container removal; new apps are installed through Discover." : "View server status without changing containers.").font(.caption).foregroundStyle(.secondary)
                    Button {
                        do {
                            error = nil
                            let request = try UnraidAuthorization(address: address, allowDockerManagement: allowDockerManagement, profileID: connectionID)
                            authorization = request
                        }
                        catch { self.error = error.localizedDescription }
                    } label: { Label("Sign in to Unraid", systemImage: "person.badge.key.fill") }
                    .disabled(busy || address.isEmpty)
                    if busy { ProgressView("Verifying your connection…") }
                } header: { Text("Connect through your server") } footer: {
                    Text("Sign in → approve AsterOS → connected. Your app credential is stored in Keychain, and your server login is remembered for Discover. Website protection such as Cloudflare Access or Organizr still requires a compatible connection route.")
                }
                if kind == .connect { Section { Text("Use the server URL from Connect’s Manage link. This does not sign into your Unraid.net account or route Docker apps through Connect.") } }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    DisclosureGroup("Use an existing API key") {
                        SecureField("Unraid API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Optional fallback for an existing key. Sign-in above creates and saves one for you.").font(.caption).foregroundStyle(.secondary)
                        Button("Test & save key") { testConnection() }.disabled(busy || address.isEmpty || key.isEmpty)
                    }
                    Button("Explore demo") { store.showDemo(); dismiss() }.disabled(busy)
                }
            }.navigationTitle(renewing == nil ? "Connect your server" : "Renew server access")
                .onAppear {
                    if !prepared, let renewing {
                        name = renewing.name; address = renewing.address.absoluteString
                        kind = renewing.connection; connectionID = renewing.id
                    }
                    localHTTPAllowed = URL(string: address).map { LocalHTTPPolicy.approved($0) } ?? false
                    prepared = true
                }
                .onChange(of: address) { _, value in localHTTPAllowed = URL(string: value).map { LocalHTTPPolicy.approved($0) } ?? false }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
                .sheet(item: $authorization) { request in
                    UnraidSignInView(request: request) { receivedKey in
                        key = receivedKey; authorization = nil; testConnection()
                    }
                }
        }
    }
    private func testConnection() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if let renewing { try await store.renewAuthorization(serverID: renewing.id, key: key) }
                else { try await store.connect(name: name, address: address, key: key, kind: kind, profileID: connectionID) }
                key = ""; dismiss()
            }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct ContainerIcon: View {
    @EnvironmentObject private var appStore: AppStore
    let container: Container
    let server: URL?
    @State private var loadedImage: UIImage?
    @ObservedObject private var customIcons = CustomIconsStore.shared
    private var customImage: UIImage? {
        guard let server else { return nil }
        return customIcons.image(app: "container:" + container.name.lowercased(), server: server)
    }
    @AppStorage("allowRemoteAppIcons") private var allowRemoteIcons = false
    @ObservedObject private var tailnet = TailnetStore.shared
    var body: some View {
        Group {
            if let image = customImage ?? loadedImage { Image(uiImage: image).resizable().scaledToFit().padding(2) }
            else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.mint.opacity(0.14))
                    Text(String(container.name.prefix(2)).uppercased()).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.mint)
                }
            }
        }.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(container.state == "RUNNING" ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10).overlay(Circle().stroke(DockTheme.background, lineWidth: 2)).offset(x: 2, y: 2)
            }
            .task(id: "\(container.iconAddress(server: server)?.absoluteString ?? "none")-\(tailnet.revision)-\(tailnet.running)-\(customImage != nil)-\(allowRemoteIcons)-\(server?.absoluteString ?? "")-\(container.name)") {
                loadedImage = nil
                guard customImage == nil else { return }
                for url in AppIconPolicy.candidates(icon: container.iconAddress(server: server)?.absoluteString, name: container.name, server: server, allowExternal: allowRemoteIcons) {
                guard !Task.isCancelled else { return }
                do {
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForResource = 15
                    config.proxyConfigurations = try await tailnet.prepare(for: url.host)
                    let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    let request: URLRequest
                    if let profile = appStore.selected, let server, profile.address == server {
                        request = try await ServerWebSession.artworkRequest(url: url, server: server, serverID: profile.id)
                    } else { request = URLRequest(url: url) }
                    let (bytes, response) = try await session.data(for: request)
                    guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 5_000_000 else { continue }
                    loadedImage = UIImage(data: bytes)
                    if loadedImage != nil { return }
                } catch { /* Try the next permitted source. */ }
                }
            }
    }
}
struct ContainerDetailsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let container: Container
    @State private var customIcon: CustomIconTarget?
    @State private var editing = false
    @State private var editor: ContainerEditorTarget?
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    HStack(spacing: 18) {
                        ContainerIcon(container: container, server: store.selected?.address)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(container.name).font(.headline)
                            Text(container.state.capitalized).foregroundStyle(.secondary)
                        }
                    }
                    Text(container.status).font(.callout)
                }
                Section {
                    Button("Change icon", systemImage: "photo") {
                        if let server = store.selected?.address { customIcon = CustomIconTarget(app: "container:" + container.name.lowercased(), name: container.name, server: server) }
                    }.disabled(store.demo)
                    if let server = store.selected, !store.demo {
                        NavigationLink { ContainerLogsView(server: server, container: container) } label: { Label("Container logs", systemImage: "text.alignleft") }
                    }
                    Button("Edit container configuration", systemImage: "slider.horizontal.3") {
                        if let server = store.selected { editor = ContainerEditorTarget(container: container, server: server) }
                    }.disabled(store.demo || store.operating || store.dockerError != nil)
                    if let configured = container.webAddress(server: store.selected?.address) {
                        LabeledContent("Unraid WebUI") { Text(configured.absoluteString).font(.caption).textSelection(.enabled) }
                        Text("Tapping the app opens its configured Unraid WebUI unless you set an external URL override.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Unraid has not supplied a usable WebUI for this container. Configure its WebUI in Unraid, or add an optional external URL.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Set external URL override") { editing = true }.disabled(store.demo)
                    let overrides = (store.selected?.apps ?? []).filter { $0.containerID == container.id || ($0.containerID == nil && $0.name.caseInsensitiveCompare(container.name) == .orderedSame) }
                    if let current = overrides.first {
                        LabeledContent("External override") { Text(current.url.absoluteString).font(.caption).textSelection(.enabled) }
                        Button("Use Unraid WebUI instead") { for app in overrides { store.removeApp(app.id) } }.disabled(store.demo)
                    }
                }
            }.navigationTitle("App details").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .fullScreenCover(item: $editor, onDismiss: { Task { await store.refresh() } }) { ContainerEditorView(target: $0) }
                .sheet(item: $customIcon) { CustomIconEditor(target: $0) }
                .sheet(isPresented: $editing) { AddAppView(initialName: container.name, containerID: container.id) }
        }
    }
}
struct AddAppView: View {
    let containerID: String?
    init(initialName: String = "", containerID: String? = nil) {
        self.containerID = containerID
        _name = State(initialValue: initialName)
    }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        NavigationStack { GlassForm {
            TextField("App name", text: $name)
            TextField("https://app.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error { Text(error).foregroundStyle(.orange) }
            Button(containerID == nil ? "Add app" : "Save override") { do { try store.addApp(name: name, address: address, containerID: containerID); dismiss() } catch { self.error = error.localizedDescription } }.disabled(address.isEmpty)
        }.navigationTitle(containerID == nil ? "Add app" : "External URL override").toolbar { Button("Cancel") { dismiss() } } }
    }
}
struct PlannedView: View {
    let title: String; let symbol: String; let detail: String
    var body: some View {
        NavigationStack { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) }.background { AsterBackdrop() }.navigationTitle(title) }
    }
}
struct SettingsView: View {
    @AppStorage("allowRemoteAppIcons") private var allowRemoteIcons = false
    @AppStorage("temporaryCleanupFailed") private var temporaryCleanupFailed = false
    @State private var renewing: ServerProfile?
    @EnvironmentObject var store: AppStore
    @State private var adding = false
    @State private var removing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            GlassForm {
                Section("Servers") {
                    ForEach(store.profiles) { profile in
                        Button { store.select(profile.id) } label: { HStack { Text(profile.name); Spacer(); if store.selectedID == profile.id { Image(systemName: "checkmark") } } }
                    }
                    Button("Add server") { adding = true }
                    Button("Explore demo") { store.showDemo() }
                    if let server = store.selected { Button("Renew server access") { renewing = server }; Button("Remove selected server", role: .destructive) { removing = true } }
                }
                Section("Security") { NavigationLink { AppSecuritySettings() } label: { Label("App security", systemImage: "lock.shield") } }
                Section("Remote access") {
                    NavigationLink { TailnetSetupView() } label: { Label("Private connection", systemImage: "network.badge.shield.half.filled") }
                }
                if let server = store.selected, !store.demo {
                    Section("Server tools") {
                        NavigationLink { ServerTerminalView(server: server) } label: { Label("Terminal", systemImage: "terminal") }
                        NavigationLink { ServerAlertsView(server: server) } label: { Label("Server alerts", systemImage: "bell") }
                        NavigationLink { PreferencesBackupView(server: server) } label: { Label("Preferences backup", systemImage: "square.and.arrow.up") }
                        Text("Desktop Commander controls are available in the terminal’s options menu.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Support") { NavigationLink { SupportReportView() } label: { Label("Support report", systemImage: "doc.text.magnifyingglass") } }
                Section("Preview build") {
                    Text("AsterOS by Asterline Labs").font(.headline)
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") • Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")")
                    Text("Includes private connectivity, server monitoring, Docker controls, direct files and resumable photo backup. Includes Discover for Unraid apps and container removal. Includes server terminal access. Optional PIN and biometric app lock are available. Unread server alerts and searchable Docker logs require compatible API permissions and server versions. Photo backup runs while this app is open; background push alerts are not included.").foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Toggle("Load icons from external hosts", isOn: $allowRemoteIcons)
                    Text("Server-hosted and cached icons load automatically. External downloads are off by default. Native app icons from external hosts can reveal your IP address and requested icon to that host. Custom icons stay on this device. Server web pages such as Discover can load their own third-party resources.").font(.caption)
                    if temporaryCleanupFailed { Text("Temporary file cleanup could not finish. Unlock the phone and restart AsterOS to retry.").foregroundStyle(.orange) }
                    Text("File transfers require the app’s private Tailscale connection. App pages require HTTPS or a known Tailscale peer routed through the app’s private connection. Original photo metadata, including location, is preserved in backups. Discover and terminal use your Unraid web session and may have administrator access. Removing a connection deletes local credentials; revoke its API key on Unraid to invalidate it on the server.").font(.caption)
                    Text("Server keys stay in the device Keychain. AsterOS has no analytics account. Photo backups upload only to your chosen server after you start them. Private connectivity uses your Tailscale account. Your Unraid web sign-in is remembered on this device for server tools. Saved server session cookies are protected in Keychain. External app websites use their own browser sessions.") }
                if let error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle("Settings").sheet(isPresented: $adding) { ConnectionView() }
                .sheet(item: $renewing) { ConnectionView(renewing: $0) }
                .confirmationDialog("Remove this connection and its saved API key?", isPresented: $removing, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { do { try store.removeSelected() } catch { self.error = error.localizedDescription } }
                }
        }
    }
}

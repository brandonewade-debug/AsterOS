import SwiftUI

@main struct AsterOSApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var lock = AppLockStore()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vpn = TailnetStore.shared
    var body: some Scene { WindowGroup { RootView().environmentObject(store).environmentObject(vpn).environmentObject(lock).tint(.mint).opacity(lock.locked || lock.shield ? 0 : 1).accessibilityHidden(lock.locked || lock.shield).background(AppSecurityWindow(lock: lock)).onChange(of: scenePhase, initial: true) { _, phase in lock.sceneChanged(phase) } } }
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
    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Server", systemImage: "server.rack", value: AppTab.server) { DashboardView() }
            Tab("Files", systemImage: "folder", value: AppTab.files) { FilesView() }
            Tab("Photos", systemImage: "photo", value: AppTab.photos) { PhotosView() }
            Tab("Apps", systemImage: "square.grid.2x2", value: AppTab.apps) { AppsView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
        }
        .preferredColorScheme(.dark)
        .task(id: scenePhase) { if scenePhase == .active { await vpn.foreground() } }
        .sheet(isPresented: $setup) { ConnectionView() }
        .onAppear { if store.selected == nil && !store.demo { setup = true } }
        .task(id: "\(store.selectedID?.uuidString ?? "none")-\(scenePhase)-\(vpn.running)") {
            guard scenePhase == .active else { return }
            if let server = store.selected, TailnetPolicy.contains(server.address.host ?? ""), !vpn.running { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
}
struct DashboardView: View {
    @EnvironmentObject var vpn: TailnetStore
    @EnvironmentObject var store: AppStore
    @State private var setup = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Panel {
                        HStack(spacing: 16) {
                            Image(systemName: "externaldrive.connected.to.line.below.fill").font(.largeTitle).foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.demo ? "Demo server" : (store.selected?.name ?? "Your server")).font(.title2.bold())
                                Text(store.demo ? "Preview • Sample data" : (store.selected?.connection.rawValue ?? "Add your first connection")).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    if store.demo { Text("DEMO MODE · All readings are examples").font(.caption.bold()).foregroundStyle(.orange) }
                    if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if let date = store.lastUpdated { Text("Last updated \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                    if let info = store.overview {
                        LazyVGrid(columns: columns, spacing: 14) {
                            metric("CPU", value: percent(store.metrics?.cpu?.percentTotal), subtitle: info.info.cpu.brand ?? "Processor", symbol: "cpu")
                            metric("Memory", value: percent(store.metrics?.memory?.percentTotal), subtitle: "Current utilization", symbol: "memorychip")
                            metric("Array", value: info.array.state.capitalized, subtitle: "Storage state", symbol: "externaldrive")
                            metric("System", value: info.info.os.release ?? "Unavailable", subtitle: info.info.os.hostname ?? "Unraid", symbol: "server.rack")
                        }
                        if let text = store.metricsError { Text(text).font(.caption).foregroundStyle(.secondary) }
                        Text("Storage").font(.title2.bold())
                        Panel {
                            let capacity = info.array.capacity.kilobytes
                            VStack(alignment: .leading, spacing: 18) {
                                Text("Array capacity").font(.headline)
                                ProgressView(value: capacity.fraction).tint(.mint)
                                Text(Capacity.displayKB(capacity.free)).font(.system(.largeTitle, design: .rounded).bold())
                                Text("Available • \(Capacity.displayKB(capacity.used)) used of \(Capacity.displayKB(capacity.total))").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(info.array.disks) { disk in
                            Panel {
                                HStack {
                                    Image(systemName: "internaldrive").foregroundStyle(.mint)
                                    VStack(alignment: .leading) { Text(disk.name ?? "Disk").font(.headline); Text(disk.status ?? "Unknown status").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(disk.temp.map { "\($0)°C" } ?? "—")
                                }
                            }
                        }
                    } else if let selected = store.selected {
                        if TailnetPolicy.contains(selected.address.host ?? ""), !vpn.running {
                            ProgressView("Connecting to Tailscale…").frame(maxWidth: .infinity)
                            Text(vpn.status).font(.caption).foregroundStyle(.secondary)
                            NavigationLink("Private connection settings") { TailnetSetupView() }
                        } else if store.loading { ProgressView("Loading your server…").frame(maxWidth: .infinity) }
                        else { Button("Retry server connection") { Task { await store.refresh() } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }
                    } else { Button("Connect a server") { setup = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }
                }.padding(20).frame(maxWidth: 900)
            }.frame(maxWidth: .infinity).background { AsterBackdrop() }
                .navigationTitle("AsterOS")
                .toolbar { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.loading || store.demo || store.selected == nil).accessibilityLabel("Refresh server") }
                .refreshable { await store.refresh() }.sheet(isPresented: $setup) { ConnectionView() }
        }
    }
    private func percent(_ value: Double?) -> String { value.map { "\(Int(min(100, max(0, $0))))%" } ?? "—" }
    private func metric(_ title: String, value: String, subtitle: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).foregroundStyle(.secondary)
                Text(value).font(.system(.title, design: .rounded).bold()).foregroundStyle(.mint)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 115, alignment: .leading).padding(16)
    }
}
struct ConnectionView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("connectionDraftName") private var name = ""
    @AppStorage("connectionDraftAddress") private var address = ""
    @State private var key = ""
    @State private var kind: ConnectionKind = .custom
    @State private var authorization: UnraidAuthorization?
    @State private var connectionID = UUID()
    @State private var allowDockerManagement = true
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
                    Text("Connect privately through Tailscale, or use your own HTTPS server address.").foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { TailnetSetupView() } label: { Label("Connect with Tailscale", systemImage: "network.badge.shield.half.filled") }
                }
                Section {
                    TextField("Server name", text: $name)
                    Picker("Method", selection: $kind) { ForEach(ConnectionKind.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("https://server.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Connection") } footer: {
                    Text("Enter your server address, then sign in below. No API key needs to be copied.")
                }
                Section {
                    Toggle("Manage Docker apps", isOn: $allowDockerManagement)
                    Text(allowDockerManagement ? "Requests Docker create, update, and delete access alongside monitoring. Allows native container removal; new apps are installed through the server App Store." : "View server status without changing containers.").font(.caption).foregroundStyle(.secondary)
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
                    Text("Sign in → approve AsterOS → connected. Your app credential is stored in Keychain, and your server login is remembered for the App Store. Website protection such as Cloudflare Access or Organizr still requires a compatible connection route.")
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
            }.navigationTitle("Connect your server")
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
            do { try await store.connect(name: name, address: address, key: key, kind: kind, profileID: connectionID); key = ""; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct ContainerIcon: View {
    let container: Container
    let server: URL?
    @State private var loadedImage: UIImage?
    @ObservedObject private var customIcons = CustomIconsStore.shared
    private var customImage: UIImage? {
        guard let server else { return nil }
        return customIcons.image(app: "container:" + container.name.lowercased(), server: server)
    }
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
            .task(id: "\(container.iconAddress(server: server)?.absoluteString ?? "none")-\(tailnet.revision)-\(tailnet.running)-\(customImage != nil)") {
                loadedImage = nil
                guard customImage == nil, let url = container.iconAddress(server: server) else { return }
                do {
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForResource = 15
                    config.proxyConfigurations = try await tailnet.prepare(for: url.host)
                    let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    let (bytes, response) = try await session.data(from: url)
                    guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 5_000_000 else { return }
                    loadedImage = UIImage(data: bytes)
                } catch { /* Keep the container initials if its icon is unavailable. */ }
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
                    Button("Edit container configuration", systemImage: "slider.horizontal.3") {
                        if let server = store.selected { editor = ContainerEditorTarget(container: container, server: server) }
                    }.disabled(store.demo || store.operating)
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
                    if store.selected != nil { Button("Remove selected server", role: .destructive) { removing = true } }
                }
                Section("Security") { NavigationLink { AppSecuritySettings() } label: { Label("App security", systemImage: "lock.shield") } }
                Section("Remote access") {
                    NavigationLink { TailnetSetupView() } label: { Label("Private connection", systemImage: "network.badge.shield.half.filled") }
                }
                if let server = store.selected, !store.demo {
                    Section("Server tools") {
                        NavigationLink { ServerTerminalView(server: server) } label: { Label("Terminal", systemImage: "terminal") }
                        Text("Desktop Commander controls are available in the terminal’s options menu.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Preview build") {
                    Text("AsterOS by Asterline Labs").font(.headline)
                    Text("0.1.0 • Preview")
                    Text("Includes private connectivity, server monitoring, Docker controls, direct files and resumable photo backup. Includes an integrated server App Store and container removal. Includes server terminal access. Optional PIN and biometric app lock are available. Notifications are still planned.").foregroundStyle(.secondary)
                }
                Section("Privacy") { Text("Server keys stay in the device Keychain. AsterOS has no analytics account. Photo backups upload only to your chosen server after you start them. Private connectivity uses your Tailscale account. App browser cookies are kept only for the current browser session.") }
                if let error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle("Settings").sheet(isPresented: $adding) { ConnectionView() }
                .confirmationDialog("Remove this connection and its saved API key?", isPresented: $removing, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { do { try store.removeSelected() } catch { self.error = error.localizedDescription } }
                }
        }
    }
}

import SwiftUI

@main struct AsterOSApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var vpn = TailnetStore.shared
    var body: some Scene { WindowGroup { RootView().environmentObject(store).environmentObject(vpn).tint(.mint) } }
}
enum DockTheme {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.08)
    static let card = Color(red: 0.095, green: 0.11, blue: 0.13)
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(DockTheme.card, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.09)))
    }
}
struct RootView: View {
    @EnvironmentObject var vpn: TailnetStore
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup = false
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Server", systemImage: "server.rack") }
            FilesView().tabItem { Label("Files", systemImage: "folder") }
            PhotosView().tabItem { Label("Photos", systemImage: "photo") }
            AppsView().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
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
                        else { Button("Retry server connection") { Task { await store.refresh() } }.buttonStyle(.borderedProminent) }
                    } else { Button("Connect a server") { setup = true }.buttonStyle(.borderedProminent) }
                }.padding(20).frame(maxWidth: 900)
            }.frame(maxWidth: .infinity).background(DockTheme.background)
                .navigationTitle("AsterOS")
                .toolbar { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.loading || store.demo || store.selected == nil).accessibilityLabel("Refresh server") }
                .refreshable { await store.refresh() }.sheet(isPresented: $setup) { ConnectionView() }
        }
    }
    private func percent(_ value: Double?) -> String { value.map { "\(Int(min(100, max(0, $0))))%" } ?? "—" }
    private func metric(_ title: String, value: String, subtitle: String, symbol: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).foregroundStyle(.secondary)
                Text(value).font(.system(.title, design: .rounded).bold()).foregroundStyle(.mint)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 115, alignment: .leading)
        }
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
    @State private var allowDockerManagement = true
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
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
                    Text(allowDockerManagement ? "Requests Docker create, update, and delete access alongside monitoring. Install/remove controls are still in development." : "View server status without changing containers.").font(.caption).foregroundStyle(.secondary)
                    Button {
                        do {
                            error = nil
                            let request = try UnraidAuthorization(address: address, allowDockerManagement: allowDockerManagement)
                            authorization = request
                        }
                        catch { self.error = error.localizedDescription }
                    } label: { Label("Sign in to Unraid", systemImage: "person.badge.key.fill") }
                    .disabled(busy || address.isEmpty)
                    if busy { ProgressView("Verifying your connection…") }
                } header: { Text("Connect through your server") } footer: {
                    Text("Sign in → approve AsterOS → connected. Your app credential is created automatically and stored in Keychain. Website protection such as Cloudflare Access or Organizr still requires a compatible connection route.")
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
            do { try await store.connect(name: name, address: address, key: key, kind: kind); key = ""; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
struct AppsView: View {
    @EnvironmentObject var store: AppStore
    @State private var adding = false
    @State private var opened: SavedApp?
    @State private var pending: Container?
    @State private var details: Container?
    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 18)]
    private func shortcut(for container: Container) -> SavedApp? {
        store.selected?.apps.first { $0.containerID == container.id || ($0.containerID == nil && $0.name.caseInsensitiveCompare(container.name) == .orderedSame) }
    }
    private func launch(_ container: Container) {
        guard !store.demo else { details = container; return }
        if let app = shortcut(for: container) { opened = app }
        else if let url = container.webAddress(server: store.selected?.address) { opened = SavedApp(name: container.name, url: url, containerID: container.id) }
        else { details = container }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.demo { Text("Demo apps • Sample data").font(.caption).foregroundStyle(.orange) }
                    if let error = store.dockerError { Text(error).font(.callout).foregroundStyle(.orange) }
                    if store.containers.isEmpty && store.dockerError == nil {
                        ContentUnavailableView("No apps loaded", systemImage: "square.grid.2x2", description: Text("Connect your Unraid server to see its Docker apps here."))
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(store.containers) { container in
                            Button { launch(container) } label: {
                                VStack(spacing: 10) {
                                    ContainerIcon(container: container, server: store.selected?.address)
                                    Text(container.name).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center).lineLimit(2).frame(height: 34, alignment: .top)
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.plain)
                            .accessibilityLabel("\(container.name), \(container.state.lowercased())")
                            .contextMenu {
                                Button("Open app", systemImage: "arrow.up.forward.app") { launch(container) }.disabled(store.demo)
                                Button("App details", systemImage: "info.circle") { details = container }
                                if container.state == "RUNNING" || container.state == "EXITED" {
                                    Button(container.state == "RUNNING" ? "Stop container" : "Start container", systemImage: container.state == "RUNNING" ? "stop.circle" : "play.circle") { pending = container }.disabled(store.demo || store.operating)
                                }
                            }
                        }
                    }
                    let extras = (store.selected?.apps ?? []).filter { app in !store.containers.contains { shortcut(for: $0)?.id == app.id } }
                    if !extras.isEmpty {
                        Text("Shortcuts").font(.headline).foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                            ForEach(extras) { app in
                                Button { opened = app } label: {
                                    VStack(spacing: 10) {
                                        Image(systemName: app.symbol).font(.largeTitle).frame(width: 72, height: 72).background(.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                                        Text(app.name).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center).lineLimit(2).frame(height: 34, alignment: .top)
                                    }.frame(maxWidth: .infinity)
                                }.buttonStyle(.plain).contextMenu { Button("Remove shortcut", role: .destructive) { store.removeApp(app.id) } }
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 24).frame(maxWidth: 900)
            }.frame(maxWidth: .infinity).background(DockTheme.background).navigationTitle("Apps")
                .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.disabled(store.selected == nil || store.demo).accessibilityLabel("Add app shortcut") }
                .sheet(isPresented: $adding) { AddAppView() }
                .sheet(item: $details) { container in ContainerDetailsView(container: container) }
                .fullScreenCover(item: $opened) { AppBrowser(app: $0) }
                .confirmationDialog("Change container state?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                    if let container = pending {
                        Button("\(container.state == "RUNNING" ? "Stop" : "Start") \(container.name)") {
                            pending = nil
                            Task { await store.perform(container.state == "RUNNING" ? .stop : .start, container: container) }
                        }
                    }
                } message: { Text("Stopping an app interrupts its active connections and work.") }
                .refreshable { await store.refresh() }
        }
    }
}
struct ContainerIcon: View {
    let container: Container
    let server: URL?
    @State private var loadedImage: UIImage?
    @ObservedObject private var tailnet = TailnetStore.shared
    var body: some View {
        Group {
            if let loadedImage { Image(uiImage: loadedImage).resizable().scaledToFit().padding(2) }
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
            .task(id: "\(container.iconAddress(server: server)?.absoluteString ?? "none")-\(tailnet.revision)-\(tailnet.running)") {
                loadedImage = nil
                guard let url = container.iconAddress(server: server) else { return }
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
    @State private var editing = false
    var body: some View {
        NavigationStack {
            Form {
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
                    Button("Set app URL") { editing = true }.disabled(store.demo)
                    Text("Set an HTTPS address to launch this app. A custom domain can be used when its local WebUI only supports HTTP.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("App details").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
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
        NavigationStack { Form {
            TextField("App name", text: $name)
            TextField("https://app.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error { Text(error).foregroundStyle(.orange) }
            Button("Add app") { do { try store.addApp(name: name, address: address, containerID: containerID); dismiss() } catch { self.error = error.localizedDescription } }.disabled(address.isEmpty)
        }.navigationTitle("Add app").toolbar { Button("Cancel") { dismiss() } } }
    }
}
struct PlannedView: View {
    let title: String; let symbol: String; let detail: String
    var body: some View {
        NavigationStack { ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) }.background(DockTheme.background).navigationTitle(title) }
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var adding = false
    @State private var removing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Servers") {
                    ForEach(store.profiles) { profile in
                        Button { store.select(profile.id) } label: { HStack { Text(profile.name); Spacer(); if store.selectedID == profile.id { Image(systemName: "checkmark") } } }
                    }
                    Button("Add server") { adding = true }
                    Button("Explore demo") { store.showDemo() }
                    if store.selected != nil { Button("Remove selected server", role: .destructive) { removing = true } }
                }
                Section("Remote access") {
                    NavigationLink { TailnetSetupView() } label: { Label("Private connection", systemImage: "network.badge.shield.half.filled") }
                }
                Section("Preview build") {
                    Text("AsterOS by Asterline Labs").font(.headline)
                    Text("0.1.0 • Development foundation")
                    Text("Photo backup, automatic routing, notifications, Face ID lock, app installation, and terminal access are not implemented yet.").foregroundStyle(.secondary)
                }
                Section("Privacy") { Text("Server keys stay in the device Keychain. This build has no analytics, cloud account, relay service, or photo uploads. App browser cookies are kept only for the current browser session.") }
                if let error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle("Settings").sheet(isPresented: $adding) { ConnectionView() }
                .confirmationDialog("Remove this connection and its saved API key?", isPresented: $removing, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { do { try store.removeSelected() } catch { self.error = error.localizedDescription } }
                }
        }
    }
}

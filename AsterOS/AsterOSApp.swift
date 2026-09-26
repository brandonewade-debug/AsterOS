import SwiftUI

@main struct AsterOSApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene { WindowGroup { RootView().environmentObject(store).tint(.mint) } }
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
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup = false
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Server", systemImage: "server.rack") }
            PlannedView(title: "Files", symbol: "folder.fill", detail: "Share browsing and resumable transfers are planned for the server companion. No files are accessed by this preview.").tabItem { Label("Files", systemImage: "folder") }
            PlannedView(title: "Photos", symbol: "photo.on.rectangle", detail: "Photo backup, albums, and Live Photos are planned. This preview does not request photo access or upload your library.").tabItem { Label("Photos", systemImage: "photo") }
            AppsView().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $setup) { ConnectionView() }
        .onAppear { if store.selected == nil && !store.demo { setup = true } }
        .task(id: "\(store.selectedID?.uuidString ?? "none")-\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
}
struct DashboardView: View {
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
                    } else if store.loading { ProgressView("Connecting…").frame(maxWidth: .infinity) }
                    else { Button("Connect a server") { setup = true }.buttonStyle(.borderedProminent) }
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
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var kind: ConnectionKind = .custom
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your server. Within reach.").font(.title2.bold())
                    Text("Connect using your own HTTPS domain, a VPN-reachable address, or your configured Unraid Connect remote URL.").foregroundStyle(.secondary)
                }
                Section {
                    TextField("Server name", text: $name)
                    Picker("Method", selection: $kind) { ForEach(ConnectionKind.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("https://server.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Unraid API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Connection") } footer: {
                    Text("Create an API key in Unraid Settings → Management Access → API. Use read access for system, array and Docker; Docker start/stop additionally needs update permission. Keys are stored in this device’s Keychain.")
                }
                if kind == .connect { Section { Text("Use the server URL from Connect’s Manage link. This does not sign into your Unraid.net account or route Docker apps through Connect.") } }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button {
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { try await store.connect(name: name, address: address, key: key, kind: kind); key = ""; dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: { HStack { Text("Test & save connection"); Spacer(); if busy { ProgressView() } } }
                    .disabled(busy || address.isEmpty || key.isEmpty)
                    Button("Explore demo") { store.showDemo(); dismiss() }.disabled(busy)
                }
            }.navigationTitle("Connect your server")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
        }
    }
}
struct AppsView: View {
    @EnvironmentObject var store: AppStore
    @State private var adding = false
    @State private var opened: SavedApp?
    @State private var pending: Container?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Launchpad").font(.title2.bold())
                    if store.selected?.apps.isEmpty != false {
                        Panel { Text("Add an app’s HTTPS URL to open it here. Each app keeps its own website login; the Unraid API key is never sent to it.").foregroundStyle(.secondary) }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 24) {
                        ForEach(store.selected?.apps ?? []) { app in
                            Button { opened = app } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: app.symbol).font(.largeTitle).frame(width: 78, height: 78).background(.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 22))
                                    Text(app.name).font(.subheadline).foregroundStyle(.white).lineLimit(2)
                                }
                            }.contextMenu { Button("Remove shortcut", role: .destructive) { store.removeApp(app.id) } }
                        }
                    }
                    Text("Containers").font(.title2.bold())
                    if store.demo { Text("Sample container • Controls disabled").foregroundStyle(.orange) }
                    if let error = store.dockerError { Text(error).foregroundStyle(.orange) }
                    if store.containers.isEmpty && store.dockerError == nil { Text("No container data loaded.").foregroundStyle(.secondary) }
                    ForEach(store.containers) { container in
                        Panel {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(container.name).font(.headline)
                                    Text(container.status).font(.caption).foregroundStyle(.secondary)
                                    Text(container.state.capitalized).font(.caption.bold()).foregroundStyle(container.state == "RUNNING" ? .mint : .orange)
                                }
                                Spacer()
                                if container.state == "RUNNING" || container.state == "EXITED" {
                                    Button(container.state == "RUNNING" ? "Stop" : "Start") { pending = container }.buttonStyle(.bordered).disabled(store.demo || store.operating)
                                }
                            }
                        }
                    }
                }.padding(20).frame(maxWidth: 900)
            }.frame(maxWidth: .infinity).background(DockTheme.background).navigationTitle("Apps")
                .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.disabled(store.selected == nil || store.demo).accessibilityLabel("Add app shortcut") }
                .sheet(isPresented: $adding) { AddAppView() }
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
struct AddAppView: View {
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
            Button("Add app") { do { try store.addApp(name: name, address: address); dismiss() } catch { self.error = error.localizedDescription } }.disabled(address.isEmpty)
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
                Section("Preview build") {
                    Text("AsterOS by Asterline Labs").font(.headline)
                    Text("0.1.0 • Development foundation")
                    Text("Files, photo backup, automatic routing, notifications, Face ID lock, app installation, and terminal access are not implemented yet.").foregroundStyle(.secondary)
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

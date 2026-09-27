import SwiftUI

/// These fixtures never construct a server client, request photo access, or write to a share.
@MainActor final class DemoWorkspace: ObservableObject {
    struct App: Identifiable, Equatable {
        var id: String
        var name: String
        var symbol: String
        var running = true
        var port = "8080"
        var path = "/mnt/user/appdata/example"
        var variable = "America/Chicago"
        var network = "bridge"
        var privileged = false
    }
    static let catalog = [
        App(id: "media", name: "Media library", symbol: "play.rectangle.fill"),
        App(id: "cloud", name: "Personal cloud", symbol: "cloud.fill"),
        App(id: "notes", name: "Notes", symbol: "note.text"),
        App(id: "home", name: "Home dashboard", symbol: "house.fill")
    ]
    @Published var apps = Array(catalog.prefix(2))
    @Published var backupCount = 0
    @Published var dayFolders = false
    @Published var separateVideos = true
    @Published var destination = "Photos/Family"
    @Published var folderMembers: Set<String> = []
    func reset() {
        apps = Array(Self.catalog.prefix(2)); backupCount = 0
        dayFolders = false; separateVideos = true; destination = "Photos/Family"; folderMembers = []
    }
    func save(_ app: App) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = app }
        else { apps.append(app) }
    }
    func remove(_ id: String) { apps.removeAll { $0.id == id }; folderMembers.remove(id) }
}
struct ConnectionProgressView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var vpn: TailnetStore
    @State private var waitingSince = Date()
    @State private var settings = false
    private var waiting: Bool {
        store.selected.map { TailnetPolicy.contains($0.address.host ?? "") && !vpn.running } ?? false
    }
    var body: some View {
        if store.selected != nil && (waiting || (store.loading && store.showConnectionProgress)) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let started = waiting ? waitingSince : store.stageStarted ?? context.date
                let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                HStack(spacing: 12) {
                    ProgressView().tint(.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(waiting ? "Connecting to Tailscale" : store.connectionStage ?? "Connecting to server").font(.subheadline.bold())
                        Text(waiting ? "\(vpn.status) · \(elapsed)s elapsed" : "\(elapsed)s elapsed · \(max(0, 30 - elapsed))s request budget remaining")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if waiting {
                            Text("Connection time depends on network and device approval.").font(.caption2).foregroundStyle(.secondary)
                        } else if elapsed >= 30 {
                            Text("Waiting for the request to finish or report a timeout.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if waiting { Button("Options") { settings = true }.font(.caption.bold()) }
                }.padding(12).background(.ultraThinMaterial)
            }
            .onChange(of: waiting, initial: true) { _, _ in waitingSince = Date() }
            .sheet(isPresented: $settings) { NavigationStack { TailnetSetupView().toolbar { Button("Done") { settings = false } } } }
        }
    }
}
struct DemoFilesView: View {
    var body: some View {
        NavigationStack {
            DemoDirectory(path: "", folders: ["Documents", "Photos", "Videos"])
                .navigationTitle("Files")
        }
    }
}
struct DemoDirectory: View {
    let path: String
    let folders: [String]
    @State private var search = ""
    private var leaf: Bool { folders.isEmpty }
    private var files: [String] {
        path.contains("Documents") ? ["Welcome.txt", "Backup checklist.txt"] :
        (path.contains("Videos") ? ["2026-09-04_10-32-18.mov", "2026-09-18_14-05-22.mov"] :
        ["2026-09-04_10-32-18.heic", "2026-09-12_09-15-00.heic", "2026-09-18_14-05-22.heic"])
    }
    var body: some View {
        List {
            Section { Text("Sample files only. No connection or file permissions are needed.").font(.caption).foregroundStyle(.secondary) }
            if leaf {
                Section("Sorted by capture day") {
                    ForEach(files.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { file in
                        NavigationLink {
                            VStack(spacing: 24) {
                                Image(systemName: file.hasSuffix(".txt") ? "doc.text" : file.hasSuffix(".mov") ? "video" : "photo").font(.system(size: 80)).foregroundStyle(.mint)
                                Text(file).font(.headline).multilineTextAlignment(.center)
                                Text(file.hasSuffix(".txt") ? "Welcome to the AsterOS demo. Your real files stay on your own server. Browse shares, choose a backup destination, and organize your apps." : "Sample media preview. This is illustrative content, not a photo from your library.")
                                    .foregroundStyle(.secondary)
                            }.padding().navigationTitle("Preview").background { AsterBackdrop() }
                        } label: { Label(file, systemImage: file.hasSuffix(".txt") ? "doc.text" : "photo") }
                    }
                }
            } else {
                ForEach(folders.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { folder in
                    NavigationLink {
                        DemoDirectory(path: path + "/" + folder, folders: folder == "Photos" || folder == "Videos" ? ["2026"] : folder == "2026" ? ["09"] : [])
                            .navigationTitle(folder)
                    } label: { Label(folder, systemImage: "folder.fill").foregroundStyle(.mint) }
                }
            }
        }.scrollContentBackground(.hidden).background { AsterBackdrop() }.searchable(text: $search, prompt: "Search sample files")
    }
}
struct DemoPhotosView: View {
    @EnvironmentObject var sample: DemoWorkspace
    @State private var backingUp = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    Label("Photo backup walkthrough", systemImage: "photo.on.rectangle").font(.headline)
                    Text("Try a simulated backup of 6 sample items. This demo never reads or uploads your photo library. Progress lasts until you exit or reset the demo.").font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Destination") {
                    Picker("Share and folder", selection: $sample.destination) {
                        Text("Photos / Family").tag("Photos/Family")
                        Text("Photos / iPhone").tag("Photos/iPhone")
                        Text("Backups / Photos").tag("Backups/Photos")
                    }
                    Toggle("Create day folders", isOn: $sample.dayFolders)
                    Toggle("Separate videos", isOn: $sample.separateVideos)
                    Text(sample.destination + (sample.separateVideos ? "/Photos" : "") + "/2026/09" + (sample.dayFolders ? "/18" : "")).font(.caption).textSelection(.enabled)
                    if sample.separateVideos { Text(sample.destination + "/Videos/2026/09" + (sample.dayFolders ? "/18" : "")).font(.caption) }
                    Text("Files keep capture dates in their names, so a month stays ordered by day.").font(.caption).foregroundStyle(.secondary)
                }.disabled(backingUp || sample.backupCount > 0)
                Section("Sample progress") {
                    ProgressView(value: Double(sample.backupCount), total: 6)
                    Text("\(sample.backupCount) of 6 sample items backed up")
                    Button(backingUp ? "Pause sample backup" : sample.backupCount == 6 ? "Sample backup complete" : sample.backupCount > 0 ? "Resume sample backup" : "Start sample backup") { backingUp.toggle() }.disabled(sample.backupCount == 6)
                    Text("Return to this tab to resume without duplicating completed sample items. Real backups also retain verified receipts across restarts.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset sample backup") { backingUp = false; sample.backupCount = 0 }
                }
            }.navigationTitle("Photos")
            .task(id: backingUp) {
                guard backingUp else { return }
                while sample.backupCount < 6 && !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard !Task.isCancelled else { return }
                    sample.backupCount += 1
                }
                backingUp = false
            }
            .onDisappear { backingUp = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { backingUp = false } }
        }
    }
}
struct DemoAppsView: View {
    @EnvironmentObject var sample: DemoWorkspace
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Explore sample apps, configuration, and installation. Changes here affect only the demo.").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 28) {
                        NavigationLink { DemoCatalogView() } label: { DemoAppTile(name: "Discover", symbol: "bag.fill") }
                        NavigationLink { DemoAppFolder() } label: { DemoAppTile(name: "Favorites", symbol: "folder.fill") }
                        ForEach(sample.apps.filter { !sample.folderMembers.contains($0.id) }) { app in
                            NavigationLink { DemoAppEditor(app: app, installing: false) } label: { DemoAppTile(name: app.name, symbol: app.symbol) }
                                .contextMenu { Button("Move to Favorites") { sample.folderMembers.insert(app.id) } }
                        }
                    }
                    NavigationLink("Reorder apps") {
                        List { ForEach(sample.apps) { Text($0.name) }.onMove { sample.apps.move(fromOffsets: $0, toOffset: $1) } }
                            .environment(\.editMode, .constant(.active)).navigationTitle("App order")
                    }
                }.padding(24)
            }.background { AsterBackdrop() }.navigationTitle("Apps")
        }
    }
}
struct DemoAppTile: View {
    let name: String
    let symbol: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.mint).frame(width: 72, height: 72).asterGlass(radius: 23)
            Text(name).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, minHeight: 108)
    }
}
struct DemoAppFolder: View {
    @EnvironmentObject var sample: DemoWorkspace
    var body: some View {
        List {
            if sample.folderMembers.isEmpty { Text("Touch and hold an app, then choose Move to Favorites.").foregroundStyle(.secondary) }
            ForEach(sample.apps.filter { sample.folderMembers.contains($0.id) }) { app in
                NavigationLink(app.name) { DemoAppEditor(app: app, installing: false) }
                    .swipeActions { Button("Move out") { sample.folderMembers.remove(app.id) } }
            }
        }.navigationTitle("Favorites")
    }
}
struct DemoCatalogView: View {
    @EnvironmentObject var sample: DemoWorkspace
    @State private var search = ""
    var body: some View {
        List {
            Section {
                Text("Sample catalog").font(.title2.bold())
                Text("On a connected server, Discover loads Unraid Community Applications. These four fictional examples are available offline.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(DemoWorkspace.catalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { app in
                NavigationLink {
                    DemoAppEditor(app: sample.apps.first { $0.id == app.id } ?? app, installing: !sample.apps.contains { $0.id == app.id })
                } label: {
                    HStack {
                        Image(systemName: app.symbol).foregroundStyle(.mint).frame(width: 36)
                        Text(app.name); Spacer()
                        Text(sample.apps.contains { $0.id == app.id } ? "Installed" : "Get").font(.caption).foregroundStyle(.mint)
                    }
                }
            }
        }.scrollContentBackground(.hidden).background { AsterBackdrop() }.navigationTitle("Discover")
            .searchable(text: $search, prompt: "Search sample apps")
    }
}
struct DemoAppEditor: View {
    @EnvironmentObject var sample: DemoWorkspace
    @Environment(\.dismiss) private var dismiss
    @State var app: DemoWorkspace.App
    let installing: Bool
    @State private var advanced = false
    @State private var confirmRemoval = false
    var body: some View {
        GlassForm {
            Section {
                Label(app.name, systemImage: app.symbol).font(.title2)
                Text("Demo configuration · No server commands are sent.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Configuration") {
                Text("Container name").font(.caption).foregroundStyle(.secondary)
                TextField("Container name", text: $app.name)
                Text("Host port").font(.caption).foregroundStyle(.secondary)
                TextField("Host port", text: $app.port).keyboardType(.numberPad)
                Text("Storage path").font(.caption).foregroundStyle(.secondary)
                TextField("Storage path", text: $app.path).textInputAutocapitalization(.never)
                Text("Time zone").font(.caption).foregroundStyle(.secondary)
                TextField("Time zone", text: $app.variable)
                Toggle("Advanced mode", isOn: $advanced)
                if advanced {
                    Picker("Network", selection: $app.network) { Text("Bridge").tag("bridge"); Text("Host").tag("host") }
                    Toggle("Privileged", isOn: $app.privileged)
                    Text("A real privileged container has broad server access. The demo only stores this selection in memory.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Icon", selection: $app.symbol) {
                    ForEach(["play.rectangle.fill", "cloud.fill", "note.text", "house.fill", "server.rack"], id: \.self) { Image(systemName: $0).tag($0) }
                }
            }
            Section {
                if !installing { Toggle("Running", isOn: $app.running) }
                Button(installing ? "Install sample app" : "Save sample changes") { sample.save(app); dismiss() }
                    .disabled(app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(app.port).map { !(1...65535).contains($0) } ?? true)
                if !installing {
                    NavigationLink("Sample logs") { ScrollView { Text("Sample log\nService started\nListening on port \(app.port)\nReady for connections").font(.system(.body, design: .monospaced)).padding() }.navigationTitle("Logs") }
                    Button("Remove sample app", role: .destructive) { confirmRemoval = true }
                }
            }
        }.navigationTitle(installing ? "Install app" : "Edit app")
        .confirmationDialog("Remove this sample app?", isPresented: $confirmRemoval) { Button("Remove", role: .destructive) { sample.remove(app.id); dismiss() } }
    }
}
struct DemoSettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sample: DemoWorkspace
    var body: some View {
        NavigationStack {
            GlassForm {
                Section("About this demo") {
                    Text("The demo is available to everyone and uses fictional data. It demonstrates navigation and selected workflows without a server, Tailscale account, or photo permission.")
                    Text("Live server authentication, file transfers, container installation, terminal connections and biometric security require setup outside the demo.").foregroundStyle(.secondary)
                }
                Section {
                    Button("Reset sample data") { sample.reset() }
                    Button("Return to my server") { store.exitDemo() }
                }
            }.navigationTitle("Settings")
        }
    }
}
extension DashboardTelemetry {
    func loadDemo() {
        reset(nil)
        func decode<T: Decodable>(_ text: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(text.utf8)) }
        live = decode(#"{"metrics":{"cpu":{"percentTotal":14},"memory":{"total":34359738368,"used":13056700580,"percentTotal":38},"network":[{"name":"eth0","operstate":"up","rxSec":24000000,"txSec":8500000,"utilizationPercent":26}]}}"#)
        packages = decode(#"{"info":{"cpu":{"packages":{"totalPower":48,"temp":[42]}}}}"#)
        storage = decode(#"{"array":{"caches":[{"id":"demo-cache","name":"Cache pool","fsType":"btrfs","status":"DISK_OK","temp":34,"fsSize":1000000000,"fsFree":750000000,"fsUsed":250000000}],"disks":[]}}"#)
        gpus = [DashboardGPU(id: "sample", name: "Sample GPU", utilization: 18, temperature: 39, power: 24, memory: 12, encoder: 8, decoder: 3, unavailable: false)]
    }
}

import SwiftUI

struct AppFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [String] = []
}
struct AppFolderLayout: Codable {
    var folders: [AppFolder] = []
    mutating func move(_ app: String, to folderID: UUID?) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        for index in folders.indices {
            folders[index].members.removeAll { $0 == app }
            if folders[index].id == folderID { folders[index].members.append(app) }
        }
    }
}
@MainActor final class AppFoldersStore: ObservableObject {
    @Published private(set) var layout = AppFolderLayout()
    @Published var error: String?
    private var key: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load(serverID: UUID?) {
        key = serverID.map { "appFolders-" + $0.uuidString }; error = nil; layout = AppFolderLayout()
        guard let key, let data = defaults.data(forKey: key) else { return }
        do { layout = try JSONDecoder().decode(AppFolderLayout.self, from: data) }
        catch { self.key = nil; self.error = "Saved app folders could not be loaded. Your saved arrangement has not been changed." }
    }
    private func persist() {
        guard let key else { return }
        do { defaults.set(try JSONEncoder().encode(layout), forKey: key) }
        catch { self.error = "Unable to save app folders." }
    }
    @discardableResult func create(_ name: String, app: String? = nil) -> UUID? {
        guard key != nil else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Enter a folder name."; return nil }
        let folder = AppFolder(name: String(name.prefix(60)))
        layout.folders.append(folder)
        if let app { layout.move(app, to: folder.id) }
        persist(); return folder.id
    }
    func rename(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = layout.folders.firstIndex(where: { $0.id == id }) else { return }
        layout.folders[index].name = String(name.prefix(60)); persist()
    }
    func move(_ app: String, to folder: UUID?) { layout.move(app, to: folder); persist() }
    func remove(_ id: UUID) { layout.folders.removeAll { $0.id == id }; persist() }
    func folder(for app: String) -> UUID? { layout.folders.first { $0.members.contains(app) }?.id }
}

struct AppLaunchItem: Identifiable {
    var container: Container?
    var shortcut: SavedApp?
    var id: String { container.map { "container:" + $0.name.lowercased() } ?? "shortcut:" + (shortcut?.id.uuidString ?? "") }
    var name: String { container?.name ?? shortcut?.name ?? "App" }
}
struct AppsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var folders = AppFoldersStore()
    @State private var adding = false
    @State private var opened: SavedApp?
    @State private var pending: Container?
    @State private var details: Container?
    @State private var openedFolder: AppFolder?
    @State private var folderPrompt = false
    @State private var folderName = ""
    @State private var editingFolder: UUID?
    @State private var movingApp: String?
    private let columns = [GridItem(.adaptive(minimum: 82, maximum: 110), spacing: 22)]
    private func shortcut(for container: Container) -> SavedApp? {
        store.selected?.apps.first { $0.containerID == container.id || ($0.containerID == nil && $0.name.caseInsensitiveCompare(container.name) == .orderedSame) }
    }
    private var items: [AppLaunchItem] {
        store.containers.map { AppLaunchItem(container: $0, shortcut: shortcut(for: $0)) } +
        (store.selected?.apps ?? []).filter { app in !store.containers.contains { shortcut(for: $0)?.id == app.id } }.map { AppLaunchItem(shortcut: $0) }
    }
    private func launch(_ item: AppLaunchItem) {
        guard !store.demo else { details = item.container; return }
        if let shortcut = item.shortcut { opened = shortcut }
        else if let container = item.container, let url = container.webAddress(server: store.selected?.address) {
            opened = SavedApp(name: container.name, url: url, containerID: container.id)
        } else { details = item.container }
    }
    private func prompt(app: String? = nil, folder: AppFolder? = nil) {
        movingApp = app; editingFolder = folder?.id; folderName = folder?.name ?? ""; folderPrompt = true
    }
    @ViewBuilder private func icon(_ item: AppLaunchItem) -> some View {
        if let container = item.container { ContainerIcon(container: container, server: store.selected?.address) }
        else { Image(systemName: item.shortcut?.symbol ?? "app.fill").font(.largeTitle).foregroundStyle(.mint).frame(width: 72, height: 72).asterGlass(radius: 23) }
    }
    private func appTile(_ item: AppLaunchItem) -> some View {
        Button { launch(item) } label: {
            VStack(spacing: 12) {
                icon(item).shadow(color: .black.opacity(0.16), radius: 10, y: 6)
                Text(item.name).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center).lineLimit(2).frame(height: 34, alignment: .top)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .contextMenu {
            Button("Open app", systemImage: "arrow.up.forward.app") { launch(item) }.disabled(store.demo)
            Menu("Move to folder", systemImage: "folder") {
                ForEach(folders.layout.folders) { folder in
                    Button(folder.name) { folders.move(item.id, to: folder.id) }
                }
                Button("New folder…", systemImage: "folder.badge.plus") { prompt(app: item.id) }
                if folders.folder(for: item.id) != nil { Button("Move out of folder", systemImage: "square.grid.2x2") { folders.move(item.id, to: nil) } }
            }.disabled(store.demo || store.selected == nil)
            if let container = item.container {
                Button("App details", systemImage: "info.circle") { details = container }
                if container.state == "RUNNING" || container.state == "EXITED" {
                    Button(container.state == "RUNNING" ? "Stop container" : "Start container", systemImage: container.state == "RUNNING" ? "stop.circle" : "play.circle") { pending = container }.disabled(store.demo || store.operating)
                }
            } else if let shortcut = item.shortcut {
                Button("Remove shortcut", role: .destructive) { folders.move(item.id, to: nil); store.removeApp(shortcut.id) }
            }
        }
    }
    private func folderTile(_ folder: AppFolder) -> some View {
        let members = items.filter { folder.members.contains($0.id) }
        return Button { openedFolder = folder } label: {
            VStack(spacing: 12) {
                ZStack {
                    if members.isEmpty { Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(.mint) }
                    else {
                        LazyVGrid(columns: [GridItem(.fixed(27), spacing: 4), GridItem(.fixed(27), spacing: 4)], spacing: 4) {
                            ForEach(Array(members.prefix(4))) { item in icon(item).scaleEffect(0.34).frame(width: 27, height: 27) }
                        }
                    }
                }.frame(width: 78, height: 78).asterGlass(radius: 25)
                Text(folder.name).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.center).lineLimit(2).frame(height: 34, alignment: .top)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).accessibilityLabel("\(folder.name), folder, \(members.count) apps")
        .contextMenu {
            Button("Rename folder", systemImage: "pencil") { prompt(folder: folder) }
            Button("Remove folder", systemImage: "folder.badge.minus") { folders.remove(folder.id) }
        }
    }
    private func appGrid(_ values: [AppLaunchItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 30) { ForEach(values) { appTile($0) } }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.demo { Text("Demo apps • Sample data").font(.caption).foregroundStyle(.orange) }
                    if let error = store.dockerError ?? folders.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    if items.isEmpty && store.dockerError == nil { ContentUnavailableView("No apps loaded", systemImage: "square.grid.2x2", description: Text("Connect your Unraid server to see its Docker apps here.")) }
                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(folders.layout.folders) { folderTile($0) }
                        ForEach(items.filter { folders.folder(for: $0.id) == nil }) { appTile($0) }
                    }
                    if !items.isEmpty { Text("Touch and hold an app to organize it.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 24).padding(.vertical, 26).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }.background { AsterBackdrop() }.navigationTitle("Apps")
            .toolbar {
                Menu {
                    Button("New folder", systemImage: "folder.badge.plus") { prompt() }
                    Button("Add external shortcut", systemImage: "link") { adding = true }
                } label: { Image(systemName: "plus") }.disabled(store.selected == nil || store.demo).accessibilityLabel("Add folder or shortcut")
            }
            .navigationDestination(item: $openedFolder) { original in
                let folder = folders.layout.folders.first { $0.id == original.id } ?? original
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        let members = items.filter { folders.folder(for: $0.id) == folder.id }
                        if members.isEmpty { ContentUnavailableView("No apps yet", systemImage: "folder", description: Text("Touch and hold an app on the Apps screen, then choose Move to folder.")) }
                        appGrid(members)
                    }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }.background { AsterBackdrop() }.navigationTitle(folder.name)
                .toolbar { Button("Rename", systemImage: "pencil") { prompt(folder: folder) } }
            }
            .sheet(isPresented: $adding) { AddAppView() }
            .sheet(item: $details) { ContainerDetailsView(container: $0) }
            .fullScreenCover(item: $opened) { AppBrowser(app: $0) }
            .alert(editingFolder == nil ? "New app folder" : "Rename folder", isPresented: $folderPrompt) {
                TextField("Folder name", text: $folderName)
                Button("Save") {
                    if let id = editingFolder { folders.rename(id, name: folderName) }
                    else { folders.create(folderName, app: movingApp) }
                }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Change container state?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let container = pending {
                    Button("\(container.state == "RUNNING" ? "Stop" : "Start") \(container.name)") {
                        pending = nil
                        Task { await store.perform(container.state == "RUNNING" ? .stop : .start, container: container) }
                    }
                }
            } message: { Text("Stopping an app interrupts its active connections and work.") }
            .refreshable { await store.refresh() }
            .task(id: store.selectedID) { openedFolder = nil; folders.load(serverID: store.demo ? nil : store.selectedID) }
        }
    }
}

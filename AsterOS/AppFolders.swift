import SwiftUI
import UniformTypeIdentifiers

struct AppFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [String] = []
}
struct AppFolderLayout: Codable {
    var folders: [AppFolder] = []
    var order: [String] = []
    init(folders: [AppFolder] = [], order: [String] = []) { self.folders = folders; self.order = order }
    private enum CodingKeys: String, CodingKey { case folders, order }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folders = try values.decode([AppFolder].self, forKey: .folders)
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
    }
    func ordered(_ ids: [String], folder: UUID? = nil) -> [String] {
        let saved = folder.flatMap { id in folders.first { $0.id == id }?.members } ?? order
        var seen = Set<String>()
        return (saved.filter { ids.contains($0) } + ids).filter { seen.insert($0).inserted }
    }
    mutating func reorder(_ app: String, over target: String, visible: [String], folder: UUID? = nil) {
        var values = ordered(visible, folder: folder)
        guard app != target, let from = values.firstIndex(of: app), let to = values.firstIndex(of: target) else { return }
        values.remove(at: from); values.insert(app, at: to)
        if let folder {
            guard let index = folders.firstIndex(where: { $0.id == folder }), values.allSatisfy({ folders[index].members.contains($0) }) else { return }
            folders[index].members = values + folders[index].members.filter { !values.contains($0) }
        } else { order = values + order.filter { !values.contains($0) } }
    }
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
    private var profileKey: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    // A profile UUID changes when a connection is re-added; its server address does not.
    static func addressKey(_ address: URL) -> String {
        var components = URLComponents(url: CatalogPolicy.url(server: address), resolvingAgainstBaseURL: false)!
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()
        if components.port == 443 { components.port = nil }
        return "appFolderAddress-" + components.string!
    }
    func load(serverID: UUID?, address: URL? = nil, knownServerIDs: [UUID] = []) {
        profileKey = serverID.map { "appFolders-" + $0.uuidString }
        key = serverID == nil ? nil : address.map(Self.addressKey) ?? profileKey
        error = nil; layout = AppFolderLayout()
        guard let key else { return }
        var data = defaults.data(forKey: key)
        if data == nil, let profileKey { data = defaults.data(forKey: profileKey) }
        // Recover the unambiguous legacy case: one saved server and one abandoned
        // layout. Never guess between several servers/layouts or replace saved data.
        if data == nil, let serverID, knownServerIDs == [serverID] {
            let activeKeys = Set(knownServerIDs.map { "appFolders-" + $0.uuidString })
            let abandoned = defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("appFolders-") && !activeKeys.contains($0)
            }
            if abandoned.count == 1 { data = defaults.data(forKey: abandoned[0]) }
        }
        guard let data else { return }
        do {
            layout = try JSONDecoder().decode(AppFolderLayout.self, from: data)
            // Keep the original bytes as a recovery copy; future edits use both keys.
            defaults.set(data, forKey: key)
            if let profileKey { defaults.set(data, forKey: profileKey) }
        } catch {
            self.key = nil; self.profileKey = nil
            self.error = "Saved app folders could not be loaded. Your saved arrangement has not been changed."
        }
    }
    private func persist() {
        guard let key else { return }
        do {
            let data = try JSONEncoder().encode(layout)
            defaults.set(data, forKey: key)
            if let profileKey { defaults.set(data, forKey: profileKey) }
        } catch { self.error = "Unable to save app folders." }
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
    func reorder(_ app: String, over target: String, visible: [String], folder: UUID? = nil) {
        layout.reorder(app, over: target, visible: visible, folder: folder); persist()
    }
    func remove(_ id: UUID) { layout.folders.removeAll { $0.id == id }; persist() }
    func folder(for app: String) -> UUID? { layout.folders.first { $0.members.contains(app) }?.id }
}

struct AppLaunchItem: Identifiable {
    var container: Container?
    var shortcut: SavedApp?
    var id: String { container.map { "container:" + $0.name.lowercased() } ?? "shortcut:" + (shortcut?.id.uuidString ?? "") }
    var name: String { container?.name ?? shortcut?.name ?? "App" }
}
struct CatalogPresentation: Identifiable {
    let server: ServerProfile
    let model: CatalogBrowserModel
    var id: UUID { server.id }
}
struct AppsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var folders = AppFoldersStore()
    @ObservedObject private var customIcons = CustomIconsStore.shared
    @State private var customIcon: CustomIconTarget?
    @State private var adding = false
    @State private var catalogPresentation: CatalogPresentation?
    @State private var catalogServerID: UUID?
    @State private var removal: ContainerRemovalTarget?
    @State private var editor: ContainerEditorTarget?
    @State private var catalogModel: CatalogBrowserModel?
    @State private var opened: SavedApp?
    @State private var pending: Container?
    @State private var details: Container?
    @State private var openedFolder: AppFolder?
    @State private var folderPrompt = false
    @State private var folderName = ""
    @State private var editingFolder: UUID?
    @State private var movingApp: String?
    @State private var draggedApp: String?
    private let columns = [GridItem(.adaptive(minimum: 82, maximum: 110), spacing: 22)]
    private func shortcut(for container: Container) -> SavedApp? {
        store.selected?.apps.first { $0.containerID == container.id || ($0.containerID == nil && $0.name.caseInsensitiveCompare(container.name) == .orderedSame) }
    }
    private var items: [AppLaunchItem] {
        store.containers.map { AppLaunchItem(container: $0, shortcut: shortcut(for: $0)) } +
        (store.selected?.apps ?? []).filter { app in !store.containers.contains { shortcut(for: $0)?.id == app.id } }.map { AppLaunchItem(shortcut: $0) }
    }
    private var rootIDs: [String] {
        folders.layout.ordered(["catalog"] + folders.layout.folders.map { "folder:" + $0.id.uuidString } + items.filter { folders.folder(for: $0.id) == nil }.map(\.id))
    }
    private func members(of folder: UUID) -> [AppLaunchItem] {
        let values = items.filter { folders.folder(for: $0.id) == folder }
        return folders.layout.ordered(values.map(\.id), folder: folder).compactMap { id in values.first { $0.id == id } }
    }
    @ViewBuilder private func reorderable<V: View>(_ view: V, id: String, folder: UUID? = nil) -> some View {
        if store.demo || store.selected == nil { view }
        else {
            view.onDrag {
                draggedApp = id
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: AppOrderDrop.type.identifier, visibility: .ownProcess) { completion in
                    completion(Data(id.utf8), nil); return nil
                }
                return provider
            }.onDrop(of: [AppOrderDrop.type], delegate: AppOrderDrop(target: id, dragged: $draggedApp) { source in
                withAnimation(.snappy) {
                    folders.reorder(source, over: id, visible: folder.map { members(of: $0).map(\.id) } ?? rootIDs, folder: folder)
                }
            })
        }
    }
    private func prepareStore() {
        guard let server = store.selected, !store.demo else { return }
        if catalogServerID != server.id || catalogModel?.catalog != CatalogPolicy.url(server: server.address) {
            catalogModel?.stopCatalogObservation(); catalogModel?.stop()
            catalogModel = CatalogBrowserModel(server: server.address, serverID: server.id)
            catalogServerID = server.id
        }
        catalogModel?.resumeCatalog()
    }
    private func openStore() {
        prepareStore()
        guard let server = store.selected, let catalogModel else { return }
        catalogPresentation = CatalogPresentation(server: server, model: catalogModel)
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
        else if let server = store.selected?.address, let image = customIcons.image(app: item.id, server: server) { Image(uiImage: image).resizable().scaledToFit().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 18)) }
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
            Button("Change icon", systemImage: "photo") {
                if let server = store.selected?.address { customIcon = CustomIconTarget(app: item.id, name: item.name, server: server) }
            }.disabled(store.demo || store.selected == nil)
            Menu("Move to folder", systemImage: "folder") {
                ForEach(folders.layout.folders) { folder in
                    Button(folder.name) { folders.move(item.id, to: folder.id) }
                }
                Button("New folder…", systemImage: "folder.badge.plus") { prompt(app: item.id) }
                if folders.folder(for: item.id) != nil { Button("Move out of folder", systemImage: "square.grid.2x2") { folders.move(item.id, to: nil) } }
            }.disabled(store.demo || store.selected == nil)
            if let container = item.container {
                Button("App details", systemImage: "info.circle") { details = container }
                Button("Edit container", systemImage: "slider.horizontal.3") { if let server = store.selected { editor = ContainerEditorTarget(container: container, server: server) } }.disabled(store.demo || store.operating || store.dockerError != nil)
                Button("Remove container", systemImage: "trash", role: .destructive) { if let serverID = store.selectedID { removal = ContainerRemovalTarget(container: container, serverID: serverID) } }.disabled(store.demo || store.operating || store.dockerError != nil)
                if container.state == "RUNNING" || container.state == "EXITED" {
                    Button(container.state == "RUNNING" ? "Stop container" : "Start container", systemImage: container.state == "RUNNING" ? "stop.circle" : "play.circle") { pending = container }.disabled(store.demo || store.operating || store.dockerError != nil)
                }
            } else if let shortcut = item.shortcut {
                Button("Remove shortcut", role: .destructive) { folders.move(item.id, to: nil); store.removeApp(shortcut.id) }
            }
        }
    }
    private func folderTile(_ folder: AppFolder) -> some View {
        let members = members(of: folder.id)
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
    private func appGrid(_ values: [AppLaunchItem], folder: UUID) -> some View {
        LazyVGrid(columns: columns, spacing: 30) { ForEach(values) { item in reorderable(appTile(item), id: item.id, folder: folder) } }
    }
    private var catalogTile: some View {
        Button { openStore() } label: {
            VStack(spacing: 12) {
                Image(systemName: "bag.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(LinearGradient(colors: [.mint, .teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .mint.opacity(0.15), radius: 12, y: 5)
                Text("Discover").font(.caption).foregroundStyle(.primary).frame(height: 34, alignment: .top)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).disabled(store.selected == nil || store.demo).accessibilityLabel("Discover Unraid apps")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.demo { Text("Demo apps • Sample data").font(.caption).foregroundStyle(.orange) }
                    if let error = store.dockerError ?? folders.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    if store.selected != nil || store.demo { ContainerHealthBanner() }
                    if items.isEmpty && store.dockerError == nil { ContentUnavailableView("No apps loaded", systemImage: "square.grid.2x2", description: Text("Connect your Unraid server to see its Docker apps here.")) }
                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(rootIDs, id: \.self) { id in
                            if id == "catalog" { reorderable(catalogTile, id: id) }
                            else if let folder = folders.layout.folders.first(where: { "folder:" + $0.id.uuidString == id }) { reorderable(folderTile(folder), id: id) }
                            else if let item = items.first(where: { $0.id == id }) { reorderable(appTile(item), id: id) }
                        }
                    }
                    if !items.isEmpty { Text("Touch and hold, then drag to reorder. Use the menu for folders and icons.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 24).padding(.vertical, 26).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }.background { AsterBackdrop() }.navigationTitle("Apps")
            .toolbar {
                Menu {
                    Button("Install new app", systemImage: "bag.badge.plus") { openStore() }
                    Button("New folder", systemImage: "folder.badge.plus") { prompt() }
                    Button("Add external shortcut", systemImage: "link") { adding = true }
                } label: { Image(systemName: "plus") }.disabled(store.selected == nil || store.demo).accessibilityLabel("Add folder or shortcut")
            }
            .navigationDestination(item: $openedFolder) { original in
                let folder = folders.layout.folders.first { $0.id == original.id } ?? original
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        let members = members(of: folder.id)
                        if members.isEmpty { ContentUnavailableView("No apps yet", systemImage: "folder", description: Text("Touch and hold an app on the Apps screen, then choose Move to folder.")) }
                        appGrid(members, folder: folder.id)
                    }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }.background { AsterBackdrop() }.navigationTitle(folder.name)
                .toolbar { Button("Rename", systemImage: "pencil") { prompt(folder: folder) } }
            }
            .sheet(item: $customIcon) { CustomIconEditor(target: $0) }
            .sheet(isPresented: $adding) { AddAppView() }
            .sheet(item: $details) { ContainerDetailsView(container: $0) }
            .sheet(item: $removal) { target in
                ContainerRemovalView(container: target.container, serverID: target.serverID) {
                    if store.selectedID == target.serverID { folders.move("container:" + target.container.name.lowercased(), to: nil) }
                }
            }
            .fullScreenCover(item: $opened) { AppBrowser(app: $0) }
            .fullScreenCover(item: $editor, onDismiss: { Task { await store.refresh() } }) { ContainerEditorView(target: $0) }
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
            .fullScreenCover(item: $catalogPresentation, onDismiss: { Task { await store.refresh() } }) { presentation in
                NativeAppStoreView(server: presentation.server, model: presentation.model)
            }
            .task(id: "\(store.selectedID?.uuidString ?? "none")-\(store.preferencesRevision)") {
                draggedApp = nil; customIcon = nil; openedFolder = nil; folders.load(serverID: store.demo ? nil : store.selectedID, address: store.selected?.address, knownServerIDs: store.profiles.map(\.id))
                if catalogServerID != store.selectedID || store.demo {
                    catalogPresentation = nil; catalogModel?.stopCatalogObservation(); catalogModel?.stop(); catalogModel = nil; catalogServerID = nil
                }
                prepareStore()
            }
            .onDisappear { if catalogPresentation == nil { catalogModel?.stopCatalogObservation(); catalogModel?.stop() } }
        }
    }
}

private struct AppOrderDrop: DropDelegate {
    static let type = UTType(exportedAs: "com.asterlinelabs.asteros.app-order")
    let target: String
    @Binding var dragged: String?
    let move: (String) -> Void
    func validateDrop(info: DropInfo) -> Bool { dragged != nil && info.hasItemsConforming(to: [Self.type]) }
    func dropEntered(info: DropInfo) { if let dragged, dragged != target { move(dragged) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
}

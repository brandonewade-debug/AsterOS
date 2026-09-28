import SwiftUI
import WebKit

enum CatalogKind: String, CaseIterable, Identifiable {
    case all, docker, plugin
    var id: String { rawValue }
    var title: String { switch self { case .all: "All"; case .docker: "Docker"; case .plugin: "Plugins" } }
}
struct CatalogApp: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let author: String
    let category: String
    let summary: String
    let icon: String
    let section: String
    let note: String
    var kind: String? = nil
    var isPlugin: Bool { kind == "plugin" || kind == "driver" || kind == "language" }
}
struct CatalogSnapshot: Codable {
    let address: URL
    let savedAt: Date
    let items: [CatalogApp]
}
enum CatalogCache {
    static func load(serverID: UUID, address: URL, defaults: UserDefaults = .standard) -> CatalogSnapshot? {
        guard let data = defaults.data(forKey: "catalogSnapshot-" + serverID.uuidString), data.count < 4_000_000,
              let saved = try? JSONDecoder().decode(CatalogSnapshot.self, from: data), saved.address == address else { return nil }
        return saved
    }
    static func save(_ items: [CatalogApp], serverID: UUID, address: URL, defaults: UserDefaults = .standard) {
        let snapshot = CatalogSnapshot(address: address, savedAt: Date(), items: Array(items.prefix(500)))
        guard let data = try? JSONEncoder().encode(snapshot), data.count < 4_000_000 else { return }
        defaults.set(data, forKey: "catalogSnapshot-" + serverID.uuidString)
    }
    static func forget(_ id: UUID) { UserDefaults.standard.removeObject(forKey: "catalogSnapshot-" + id.uuidString) }
}
struct CatalogCategory: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
}
struct NativeCatalogPage: Decodable {
    let categories: [CatalogCategory]
    let items: [CatalogApp]
    let busy: Bool
    let ready: Bool
    let next: Bool
    let previous: Bool
}
enum NativeCatalogBridge {
    // Reads only public catalog-card metadata; never reads login fields, cookies or tokens.
    static let snapshot = #"""
    const clean = value => (value || '').replace(/\s+/g, ' ').trim();
    const cards = Array.from(document.querySelectorAll('.ca_holder[data-apppath][data-appname]'));
    const seen = new Set();
    const items = cards.filter(card => !card.classList.contains('ca_repoPopup') && !!card.querySelector('.appDocker, .appPlugin, .appDriver, .appLanguage')).map(card => {
        const id = card.getAttribute('data-apppath') + '|' + card.getAttribute('data-appname');
        if (seen.has(id)) return null; seen.add(id);
        const text = selector => clean(card.querySelector(selector)?.textContent);
        const image = card.querySelector('.ca_displayIcon, .ca_iconArea img');
        let icon = image?.getAttribute('src') || ''; try { icon = icon ? new URL(icon, location.href).href : ''; } catch { icon = ''; }
        const parent = card.closest('[data-des]');
        const section = clean(parent?.getAttribute('data-des') || 'Discover');
        const notes = Array.from(card.querySelectorAll('.cardWarning, .installedCardText, .betaPopupText')).map(el => clean(el.getAttribute('title') || el.textContent)).filter(Boolean).join(' · ');
        return {id, name: clean(card.getAttribute('data-appname')), author: text('.ca_author') || clean(card.getAttribute('data-repository')),
            category: text('.cardCategory'), summary: text('.cardDesc'), icon, section, note: notes,
            kind: card.querySelector('.appDriver') ? 'driver' : card.querySelector('.appLanguage') ? 'language' : card.querySelector('.appPlugin') ? 'plugin' : 'docker'};
    }).filter(Boolean).slice(0, 500);
    const enabled = selector => Array.from(document.querySelectorAll(selector)).some(el => !el.classList.contains('pageNavNoClick') && el.hasAttribute('onclick'));
    const categories = [];
    const categoryIDs = new Set();
    for (const menu of document.querySelectorAll('.categoryMenu[data-category]')) {
        const id = menu.getAttribute('data-category');
        if (!id || categoryIDs.has(id)) continue;
        categoryIDs.add(id);
        const parent = menu.closest('.subCategory')?.previousElementSibling;
        categories.push({id, name: (parent ? clean(parent.textContent) + ' › ' : '') + clean(menu.textContent)});
    }
    return JSON.stringify({items, categories, busy: (typeof data !== 'undefined' && !!data.searchInProgress) || (typeof jQuery !== 'undefined' && jQuery.active > 0),
        ready: cards.length > 0 || !!document.querySelector('.ca_NoAppsFound'),
        next: enabled('.pageRight'), previous: enabled('.pageLeft')});
    """#
    static let search = #"""
    const box = document.querySelector('#searchBox');
    if (!box || typeof doSearch !== 'function') return false;
    box.value = query; doSearch(false, query); return true;
    """#
    static let category = #"""
    const matches = Array.from(document.querySelectorAll('.categoryMenu[data-category]')).filter(el => el.getAttribute('data-category') === categoryID);
    const menu = matches.find(el => el.classList.contains('caCategoryAll')) || matches[0];
    if (!menu || typeof clearSearchBox !== 'function' || typeof changeCategory !== 'function') return false;
    // The server menu performs its own sort initialization and full-catalog request.
    // Newer CA versions use an "All" child for parent categories.
    clearSearchBox();
    if (typeof data !== 'undefined') { data.searchFlag = false; data.committedSearchFilter = ''; }
    document.querySelectorAll('.selectedMenu').forEach(el => el.classList.remove('selectedMenu'));
    menu.click();
    return true;
    """#
    // CA versions without a server-side type filter still paginate their full
    // result set. Seek matching pages instead of treating the first page as all.
    static let seekKind = #"""
    if (kind === 'all') return 'ready';
    const deadline = Date.now() + 25000;
    const sleep = () => new Promise(resolve => setTimeout(resolve, 150));
    const busy = () => (typeof data !== 'undefined' && !!data.searchInProgress) || (typeof jQuery !== 'undefined' && jQuery.active > 0);
    const matches = () => Array.from(document.querySelectorAll('.ca_holder[data-apppath][data-appname]'))
        .some(card => !card.classList.contains('ca_repoPopup') && card.querySelector(kind === 'plugin' ? '.appPlugin, .appDriver, .appLanguage' : '.appDocker'));
    while (Date.now() < deadline) {
        await sleep();
        if (busy()) continue;
        if (matches()) return 'ready';
        const selector = forward ? '.pageRight' : '.pageLeft';
        const button = Array.from(document.querySelectorAll(selector)).find(el => !el.classList.contains('pageNavNoClick') && el.hasAttribute('onclick'));
        if (!button) return 'end';
        const before = typeof data !== 'undefined' ? data.currentpage : null;
        button.click();
        await sleep();
        while (busy() && Date.now() < deadline) await sleep();
        if (before != null && typeof data !== 'undefined' && data.currentpage === before && !busy()) return 'unavailable';
    }
    return 'pending';
    """#
    static let page = #"""
    const selector = forward ? '.pageRight' : '.pageLeft';
    const button = Array.from(document.querySelectorAll(selector)).find(el => !el.classList.contains('pageNavNoClick') && el.hasAttribute('onclick'));
    if (!button) return false; button.click(); return true;
    """#
    static let review = #"""
    const card = Array.from(document.querySelectorAll('.ca_holder[data-apppath][data-appname]')).find(el => el.getAttribute('data-apppath') + '|' + el.getAttribute('data-appname') === appID);
    if (!card) return false;
    // Enter the server's information/requirements panel, retaining its own safety and compatibility checks.
    const info = card.querySelector('.infoButton, .ca_iconArea, .ca_applicationName');
    if (!info) return false; info.click(); return true;
    """#
}
@MainActor enum CatalogImageCache {
    static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>(); cache.countLimit = 200; cache.totalCostLimit = 32 * 1024 * 1024; return cache
    }()
}
struct CatalogArtwork: View {
    let app: CatalogApp
    let server: URL
    @ObservedObject private var tailnet = TailnetStore.shared
    @AppStorage("allowRemoteAppIcons") private var allowRemoteIcons = false
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "shippingbox.fill").resizable().scaledToFit().padding(14).foregroundStyle(.mint.gradient) }
        }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: app.icon + app.name + server.absoluteString + String(allowRemoteIcons) + String(tailnet.revision) + String(tailnet.running)) {
            image = nil
            for url in AppIconPolicy.candidates(icon: app.icon, name: app.name, server: server, allowExternal: allowRemoteIcons) {
            guard !Task.isCancelled else { return }
            if let cached = CatalogImageCache.images.object(forKey: url as NSURL) { image = cached; return }
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 12
                configuration.proxyConfigurations = try await TailnetStore.shared.prepare(for: url.host)
                let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000, !Task.isCancelled else { continue }
                image = UIImage(data: data)
                if let image { CatalogImageCache.images.setObject(image, forKey: url as NSURL, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count); return }
            } catch { }
            }
        }
    }
}
struct NativeAppStoreView: View {
    let server: ServerProfile
    @ObservedObject var model: CatalogBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: CatalogApp?
    @State private var showServer = false
    @State private var loginOnly = false
    @State private var discardEditor = false
    @State private var categoryPicker: CatalogCategorySelection?
    private var visible: [CatalogApp] { model.catalogItems.filter { model.catalogKind == .all || ($0.isPlugin ? model.catalogKind == .plugin : model.catalogKind == .docker) } }
    var body: some View {
        NavigationStack {
            ZStack {
                AsterBackdrop()
                if showServer {
                    if model.nativeEditor != nil || model.applyingConfiguration || model.configurationResult != nil {
                        ZStack {
                            CatalogSurface(model: model).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                            NativeContainerForm(model: model)
                        }
                    } else { UnraidAppStoreView(server: server, model: model) }
                } else {
                    CatalogSurface(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack(spacing: 16) {
                                Image(systemName: "bag.fill").font(.system(size: 38, weight: .light)).foregroundStyle(.mint.gradient)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Make your server yours.").font(.title2.bold())
                                    Text("Community Applications · \(server.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 10)
                            Picker("App type", selection: Binding(get: { model.catalogKind }, set: { value in
                                Task { await model.selectCatalogKind(value, query: query) }
                            })) {
                                ForEach(CatalogKind.allCases) { kind in Text(kind.title).tag(kind) }
                            }.pickerStyle(.segmented).disabled(model.catalogBusy || model.catalogFiltering || !model.catalogLive)
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search Unraid apps", text: $query).disabled(!model.catalogLive).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                                    .onSubmit { Task { await model.searchCatalog(query) } }
                                Button { Task { await model.searchCatalog(query) } } label: { Image(systemName: "arrow.right.circle.fill") }.accessibilityLabel("Search catalog").disabled(model.catalogBusy || model.catalogFiltering || !model.catalogLive)
                            }.padding(16).asterGlass(radius: 28)
                            if model.catalogBusy || model.catalogFiltering || model.loading || model.catalogRefreshing { ProgressView(model.catalogReady ? "Refreshing apps…" : "Loading apps from your server…").frame(maxWidth: .infinity) }
                            if model.catalogReady && !model.catalogLive { Text("You can browse these listings while the live catalog refreshes.").font(.caption).foregroundStyle(.secondary) }
                            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if model.needsCatalogLogin {
                                ContentUnavailableView {
                                    Label("Connect to the catalog", systemImage: "person.crop.circle")
                                } description: { Text("Sign in to load Community Applications. AsterOS remembers this server’s session until it expires or you sign out.") }
                                Button("Sign in to server") { loginOnly = true; showServer = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            }
                            if model.catalogReady {
                                HStack {
                                    Text(model.catalogCategory?.name ?? (query.isEmpty ? "Discover" : "Search results")).font(.title2.bold())
                                    Spacer()
                                    if !model.catalogCategories.isEmpty {
                                        Button {
                                            categoryPicker = CatalogCategorySelection(categories: model.catalogCategories, selectedID: model.catalogCategory?.id)
                                        } label: { Label("Category", systemImage: "line.3.horizontal.decrease") }
                                        .font(.caption).disabled(model.catalogBusy || model.catalogFiltering || !model.catalogLive)
                                    }
                                }
                                if visible.isEmpty && !model.catalogBusy && !model.catalogFiltering {
                                    ContentUnavailableView("No matching apps on this page", systemImage: "magnifyingglass", description: Text(model.catalogNext ? "Use Next to continue through the catalog." : "Try another category, search, or app type."))
                                }
                                LazyVStack(spacing: 24) {
                                    ForEach(visible) { app in
                                        Button { selected = app } label: {
                                            HStack(alignment: .top, spacing: 16) {
                                                CatalogArtwork(app: app, server: server.address)
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(app.name).font(.headline).foregroundStyle(.primary)
                                                    Text(app.isPlugin ? "Plugin" : "Docker").font(.caption2).foregroundStyle(.secondary)
                                                    Text(app.category.isEmpty ? app.author : app.category).font(.caption).foregroundStyle(.mint)
                                                    Text(app.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).padding(.top, 23)
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }
                                HStack {
                                    Button("Previous") { Task { await model.catalogPage(forward: false) } }.disabled(!model.catalogPrevious || model.catalogBusy || model.catalogFiltering || !model.catalogLive)
                                    Spacer()
                                    Button("Next") { Task { await model.catalogPage(forward: true) } }.disabled(!model.catalogNext || model.catalogBusy || model.catalogFiltering || !model.catalogLive)
                                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                                Text("Browse all apps in a category. Use Next to see more results.").font(.caption2).foregroundStyle(.secondary)
                            } else if !model.catalogRefreshing && !model.needsCatalogLogin && model.error != nil {
                                Text("The live catalog is taking longer than expected. You can retry or check the server view.").font(.subheadline).foregroundStyle(.secondary)
                                Button("Retry catalog") { model.openCatalog() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                                Button("Open server view") { loginOnly = false; showServer = true }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                            }
                        }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.refreshable { query = ""; model.openCatalog() }
                }
            }.navigationTitle(showServer ? (model.nativeEditor != nil ? "Configure app" : "App requirements") : "Discover").navigationBarTitleDisplayMode(showServer ? .inline : .large)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(showServer ? "Catalog" : "Done") { if showServer { if model.nativeEditor != nil { discardEditor = true } else { showServer = false; loginOnly = false; model.openCatalog() } } else { dismiss() } }.disabled(model.applyingConfiguration)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !showServer { Button { loginOnly = false; showServer = true } label: { Image(systemName: "globe") }.accessibilityLabel("Open server installer") }
                    }
                }
                .interactiveDismissDisabled(model.applyingConfiguration || model.nativeEditor != nil)
                .confirmationDialog("Discard unapplied changes?", isPresented: $discardEditor, titleVisibility: .visible) { Button("Discard changes", role: .destructive) { showServer = false; loginOnly = false; model.openCatalog() } }
                .sheet(item: $categoryPicker) { selection in
                    CatalogCategoryPicker(selection: selection) { category in
                        categoryPicker = nil; query = ""
                        if let category { Task { await model.selectCatalogCategory(category) } }
                        else { model.openCatalog() }
                    }
                }
                .sheet(item: $selected) { app in
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                HStack(spacing: 18) { CatalogArtwork(app: app, server: server.address); VStack(alignment: .leading, spacing: 5) { Text(app.name).font(.title2.bold()); Text(app.author).font(.caption).foregroundStyle(.secondary) } }
                                if !app.category.isEmpty { Text(app.category).font(.subheadline).foregroundStyle(.mint) }
                                Text(app.summary.isEmpty ? "No description supplied by this template." : app.summary)
                                if !app.note.isEmpty { Label(app.note, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary) }
                                Button(app.isPlugin ? "Review plugin installation" : "Review installation in Unraid") {
                                    selected = nil; loginOnly = false; showServer = true
                                    Task { await model.reviewCatalogApp(app) }
                                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(!model.catalogLive || model.catalogBusy || model.catalogFiltering)
                                if !model.catalogLive { Text("Installation becomes available when the live catalog is ready.").font(.caption).foregroundStyle(.secondary) }
                                Text(app.isPlugin ? "Plugins run directly on Unraid. Review the server’s requirements and press Install in its installer. Progress, errors, and any restart instructions appear there. Plugin settings are available after installation." : "Review the app’s requirements, then configure its ports, paths and settings in AsterOS before installing.").font(.caption).foregroundStyle(.secondary)
                            }.padding(24)
                        }.background { AsterBackdrop() }.navigationTitle("App details").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Done") { selected = nil } }
                    }
                }
                .onChange(of: model.catalogLive) { _, ready in if ready && loginOnly { showServer = false; loginOnly = false } }
                .onAppear { model.resumeCatalog() }
                .onDisappear { model.stopCatalogObservation(); model.stop() }
        }
    }
}


// Capture the menu once when opening it. Live catalog polling must not rebuild
// a long category list while the user is scrolling.
struct CatalogCategorySelection: Identifiable {
    let id = UUID()
    let categories: [CatalogCategory]
    let selectedID: String?
}
struct CatalogCategoryPicker: View {
    let selection: CatalogCategorySelection
    let choose: (CatalogCategory?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var categories: [CatalogCategory] {
        selection.categories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Button { choose(nil) } label: {
                        HStack {
                            Text("Discover")
                            Spacer()
                            if selection.selectedID == nil { Image(systemName: "checkmark") }
                        }
                    }
                }
                ForEach(categories) { category in
                    Button { choose(category) } label: {
                        HStack {
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            if selection.selectedID == category.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AsterBackdrop() }
            .searchable(text: $search, prompt: "Find a category")
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.mint)
    }
}

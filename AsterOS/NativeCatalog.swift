import SwiftUI
import WebKit

struct CatalogApp: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let author: String
    let category: String
    let summary: String
    let icon: String
    let section: String
    let note: String
}
struct NativeCatalogPage: Decodable {
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
    const items = cards.filter(card => !card.classList.contains('ca_repoPopup') && !!card.querySelector('.appDocker')).map(card => {
        const id = card.getAttribute('data-apppath') + '|' + card.getAttribute('data-appname');
        if (seen.has(id)) return null; seen.add(id);
        const text = selector => clean(card.querySelector(selector)?.textContent);
        const image = card.querySelector('.ca_displayIcon, .ca_iconArea img');
        let icon = image?.getAttribute('src') || ''; try { icon = icon ? new URL(icon, location.href).href : ''; } catch { icon = ''; }
        const parent = card.closest('[data-des]');
        const section = clean(parent?.getAttribute('data-des') || 'Discover');
        const notes = Array.from(card.querySelectorAll('.cardWarning, .installedCardText, .betaPopupText')).map(el => clean(el.getAttribute('title') || el.textContent)).filter(Boolean).join(' · ');
        return {id, name: clean(card.getAttribute('data-appname')), author: text('.ca_author') || clean(card.getAttribute('data-repository')),
            category: text('.cardCategory'), summary: text('.cardDesc'), icon, section, note: notes};
    }).filter(Boolean).slice(0, 500);
    const enabled = selector => Array.from(document.querySelectorAll(selector)).some(el => !el.classList.contains('pageNavNoClick') && el.hasAttribute('onclick'));
    return JSON.stringify({items, busy: typeof data !== 'undefined' && !!data.searchInProgress,
        ready: cards.length > 0 || !!document.querySelector('.ca_NoAppsFound'),
        next: enabled('.pageRight'), previous: enabled('.pageLeft')});
    """#
    static let search = #"""
    const box = document.querySelector('#searchBox');
    if (!box || typeof doSearch !== 'function') return false;
    box.value = query; doSearch(false, query); return true;
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
struct CatalogArtwork: View {
    let app: CatalogApp
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "shippingbox.fill").resizable().scaledToFit().padding(14).foregroundStyle(.mint.gradient) }
        }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: app.icon) {
            guard let url = URL(string: app.icon), url.scheme == "https", url.user == nil, url.password == nil else { return }
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 12
                configuration.proxyConfigurations = try await TailnetStore.shared.prepare(for: url.host)
                let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000, !Task.isCancelled else { return }
                image = UIImage(data: data)
            } catch { }
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
    @State private var category = "All"
    private var categories: [String] { ["All"] + Array(Set(model.catalogItems.map(\.category).filter { !$0.isEmpty })).sorted() }
    private var visible: [CatalogApp] { model.catalogItems.filter { category == "All" || $0.category == category } }
    var body: some View {
        NavigationStack {
            ZStack {
                AsterBackdrop()
                if showServer {
                    UnraidAppStoreView(server: server, model: model)
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
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search Unraid apps", text: $query).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                                    .onSubmit { category = "All"; Task { await model.searchCatalog(query) } }
                                Button { category = "All"; Task { await model.searchCatalog(query) } } label: { Image(systemName: "arrow.right.circle.fill") }.accessibilityLabel("Search catalog").disabled(model.catalogBusy)
                            }.padding(16).asterGlass(radius: 28)
                            if model.catalogBusy || model.loading { ProgressView("Loading catalog…").frame(maxWidth: .infinity) }
                            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if model.needsCatalogLogin {
                                ContentUnavailableView {
                                    Label("Connect to the catalog", systemImage: "person.crop.circle")
                                } description: { Text("Sign in on your Unraid server once to load its Community Applications catalog.") }
                                Button("Sign in to server") { loginOnly = true; showServer = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            } else if model.catalogReady {
                                HStack {
                                    Text(query.isEmpty ? "Discover" : "Search results").font(.title2.bold())
                                    Spacer()
                                    if categories.count > 2 {
                                        Menu { ForEach(categories, id: \.self) { value in Button(value) { category = value } } } label: { Label(category == "All" ? "Category" : category, systemImage: "line.3.horizontal.decrease") }.font(.caption)
                                    }
                                }
                                if visible.isEmpty { ContentUnavailableView.search(text: query) }
                                LazyVStack(spacing: 24) {
                                    ForEach(visible) { app in
                                        Button { selected = app } label: {
                                            HStack(alignment: .top, spacing: 16) {
                                                CatalogArtwork(app: app)
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(app.name).font(.headline).foregroundStyle(.primary)
                                                    Text(app.category.isEmpty ? app.author : app.category).font(.caption).foregroundStyle(.mint)
                                                    Text(app.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).padding(.top, 23)
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }
                                HStack {
                                    Button("Previous") { category = "All"; Task { await model.catalogPage(forward: false) } }.disabled(!model.catalogPrevious || model.catalogBusy)
                                    Spacer()
                                    Button("Next") { category = "All"; Task { await model.catalogPage(forward: true) } }.disabled(!model.catalogNext || model.catalogBusy)
                                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                                Text("Categories filter this page. Search queries your server’s catalog.").font(.caption2).foregroundStyle(.secondary)
                            } else if !model.loading {
                                Text("Waiting for Community Applications. If your server needs setup or uses an unsupported catalog version, open the server view.").font(.subheadline).foregroundStyle(.secondary)
                                Button("Open server view") { loginOnly = false; showServer = true }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                            }
                        }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.refreshable { query = ""; category = "All"; model.openCatalog() }
                }
            }.navigationTitle(showServer ? "Unraid installer" : "App Store").navigationBarTitleDisplayMode(showServer ? .inline : .large)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(showServer ? "Catalog" : "Done") { if showServer { showServer = false; loginOnly = false; model.openCatalog() } else { dismiss() } }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !showServer { Button { loginOnly = false; showServer = true } label: { Image(systemName: "globe") }.accessibilityLabel("Open server installer") }
                    }
                }
                .sheet(item: $selected) { app in
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                HStack(spacing: 18) { CatalogArtwork(app: app); VStack(alignment: .leading, spacing: 5) { Text(app.name).font(.title2.bold()); Text(app.author).font(.caption).foregroundStyle(.secondary) } }
                                if !app.category.isEmpty { Text(app.category).font(.subheadline).foregroundStyle(.mint) }
                                Text(app.summary.isEmpty ? "No description supplied by this template." : app.summary)
                                if !app.note.isEmpty { Label(app.note, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary) }
                                Button("Review installation in Unraid") {
                                    selected = nil; loginOnly = false; showServer = true
                                    Task { await model.reviewCatalogApp(app) }
                                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                Text("Review compatibility notes, ports and storage paths in the server installer before applying. Nothing installs when you browse or open these details.").font(.caption).foregroundStyle(.secondary)
                            }.padding(24)
                        }.background { AsterBackdrop() }.navigationTitle("App details").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Done") { selected = nil } }
                    }
                }
                .onChange(of: model.catalogReady) { _, ready in if ready && loginOnly { showServer = false; loginOnly = false } }
                .onAppear { model.startCatalogObservation() }
                .onDisappear { model.stopCatalogObservation() }
        }
    }
}

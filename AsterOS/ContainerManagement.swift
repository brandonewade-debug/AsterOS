import SwiftUI
import WebKit
import Combine

struct ContainerRemovalTarget: Identifiable {
    let container: Container
    let serverID: UUID
    var id: String { serverID.uuidString + ":" + container.id }
}
struct ContainerRemovalView: View {
    let container: Container
    let serverID: UUID
    var onRemoved: () -> Void = {}
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    Label(container.name, systemImage: "shippingbox").font(.title2.bold())
                    Text("Remove this container from \(store.profiles.first { $0.id == serverID }?.name ?? "your server")?")
                    Text("A running container will be stopped immediately. Its container configuration and files stored only inside the container will be removed.")
                    Text("The Docker image, mounted shares, volumes and app-data folders are kept. You can reinstall later from the App Store.").foregroundStyle(.secondary)
                }
                Section {
                    if removing { ProgressView("Removing container…") }
                    if let error { Text(error).foregroundStyle(.orange) }
                    Button("Remove \(container.name)", role: .destructive) {
                        removing = true; error = nil
                        Task {
                            defer { removing = false }
                            do {
                                try await store.removeContainer(container, from: serverID)
                                onRemoved(); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(removing || store.operating || store.selectedID != serverID)
                    Text("Requires Docker delete permission. If access is denied, sign in again with Manage Docker apps enabled. If the connection fails, refresh Apps before retrying; the request may already have completed.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Remove container").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() }.disabled(removing) }
                .interactiveDismissDisabled(removing)
        }
    }
}
enum CatalogPolicy {
    static func url(server: URL) -> URL {
        var base = server
        if base.lastPathComponent == "graphql" { base.deleteLastPathComponent() }
        return base.appendingPathComponent("Apps")
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == "https" && b.scheme?.lowercased() == "https" &&
        a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443)
    }
    static func returnAfterLogin(_ url: URL, catalog: URL, sawLogin: Bool) -> Bool {
        sawLogin && sameOrigin(url, catalog) && ["main", "dashboard"].contains(url.lastPathComponent.lowercased())
    }
}
@MainActor enum CatalogSession {
    static func dataStore(serverID: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: serverID)
    }
    static func forget(serverID: UUID) throws {
        try ServerWebSession.forget(serverID)
        CatalogCache.forget(serverID)
        dataStore(serverID: serverID).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { }
    }
}
struct CatalogDialog {
    let message: String
    let host: String
    let confirm: Bool
    let complete: (Bool) -> Void
}
@MainActor final class CatalogBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let catalog: URL
    private let serverID: UUID
    private var cacheable = true
    private var lastCachedItems: [CatalogApp]?
    private var connectionRevision = UUID()
    private var catalogDeadline: Task<Void, Never>?
    @Published private(set) var catalogLive = false
    @Published private(set) var catalogRefreshing = true
    let session: ServerWebSession
    @Published var catalogItems: [CatalogApp] = []
    @Published var catalogReady = false
    @Published var catalogBusy = false
    @Published var catalogNext = false
    @Published var catalogPrevious = false
    @Published var needsCatalogLogin = false
    private var catalogObservation: Task<Void, Never>?
    @Published var loading = false
    @Published var error: String?
    @Published var dialog: CatalogDialog?
    @Published var canGoBack = false
    @Published var host = ""
    private var observer: AnyCancellable?
    private var sawLogin = false
    private var timeout: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    init(server: URL, serverID: UUID) {
        self.serverID = serverID
        catalog = CatalogPolicy.url(server: server)
        let config = WKWebViewConfiguration()
        // The server owns its login and install forms. No API keys or password scraping.
        config.websiteDataStore = CatalogSession.dataStore(serverID: serverID)
        session = ServerWebSession(serverID: serverID, server: server, dataStore: config.websiteDataStore)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780), configuration: config)
        super.init()
        if let saved = CatalogCache.load(serverID: serverID, address: catalog) {
            catalogItems = saved.items; lastCachedItems = saved.items; catalogReady = true
        }
        session.onError = { [weak self] message in self?.error = message }
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observer = TailnetStore.shared.$revision.dropFirst().sink { [weak self] _ in
            self?.webView.configuration.websiteDataStore.proxyConfigurations = TailnetStore.shared.proxies
        }
    }
    func resumeCatalog() {
        if connectionTask == nil && (webView.url == nil || !onCatalog || (!catalogLive && !webView.isLoading && !needsCatalogLogin)) { openCatalog() }
        startCatalogObservation()
    }
    func openCatalog() {
        error = nil; loading = true; catalogLive = false; catalogRefreshing = true; needsCatalogLogin = false; cacheable = true
        catalogDeadline?.cancel()
        catalogDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !catalogLive else { return }
            catalogRefreshing = false
            error = "Your server is still preparing Community Applications. Retry or check the server view."
        }
        connectionTask?.cancel()
        let revision = UUID(); connectionRevision = revision
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if connectionRevision == revision { connectionTask = nil } }
            do {
                try await session.restore()
                let proxies = try await TailnetStore.shared.prepare(for: catalog.host)
                try Task.checkCancellation()
                webView.configuration.websiteDataStore.proxyConfigurations = proxies
                webView.load(URLRequest(url: catalog))
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription; self.loading = false; self.catalogRefreshing = false; self.catalogDeadline?.cancel() }
        }
    }
    private var onCatalog: Bool {
        guard let url = webView.url else { return false }
        return CatalogPolicy.sameOrigin(url, catalog) && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == catalog.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    func startCatalogObservation() {
        guard catalogObservation == nil else { return }
        catalogObservation = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readNativeCatalog()
                do { try await Task.sleep(for: .milliseconds(self?.catalogLive == true ? 1500 : 300)) } catch { break }
            }
        }
    }
    func stopCatalogObservation() { catalogObservation?.cancel(); catalogObservation = nil }
    private func readNativeCatalog() async {
        guard onCatalog else { return }
        do {
            guard let json = try await webView.callAsyncJavaScript(NativeCatalogBridge.snapshot, arguments: [:], in: nil, contentWorld: .page) as? String,
                  let bytes = json.data(using: .utf8), bytes.count < 4_000_000 else { return }
            let page = try JSONDecoder().decode(NativeCatalogPage.self, from: bytes)
            guard !Task.isCancelled, onCatalog else { return }
            catalogBusy = page.busy
            if page.ready {
                // Show cards as they arrive; installation stays gated until CA finishes.
                let changed = catalogItems != page.items
                if changed { catalogItems = page.items }
                catalogReady = true; needsCatalogLogin = false
                catalogLive = !page.busy; catalogRefreshing = page.busy
                if !page.busy {
                    loading = false; timeout?.cancel(); catalogDeadline?.cancel(); error = nil
                    if cacheable && lastCachedItems != page.items {
                        CatalogCache.save(page.items, serverID: serverID, address: catalog)
                        lastCachedItems = page.items
                    }
                }
                catalogNext = page.next; catalogPrevious = page.previous
            }
        } catch { /* Server view remains available if the plugin markup has changed. */ }
    }
    func searchCatalog(_ query: String) async {
        guard onCatalog, catalogLive else { return }
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !query.isEmpty else { openCatalog(); return }
        cacheable = false; catalogBusy = true; error = nil
        do {
            let ok = try await webView.callAsyncJavaScript(NativeCatalogBridge.search, arguments: ["query": query], in: nil, contentWorld: .page) as? Bool
            if ok != true { error = "Search is unavailable for this catalog version. Use the server view."; catalogBusy = false }
        } catch { self.error = "Could not search the server catalog."; catalogBusy = false }
    }
    func catalogPage(forward: Bool) async {
        guard onCatalog, catalogLive else { return }
        cacheable = false
        do { _ = try await webView.callAsyncJavaScript(NativeCatalogBridge.page, arguments: ["forward": forward], in: nil, contentWorld: .page) }
        catch { self.error = "Could not load the next catalog page." }
    }
    func reviewCatalogApp(_ app: CatalogApp) async {
        guard onCatalog, catalogLive, !catalogBusy else { error = "Wait for the live catalog before reviewing installation."; return }
        do {
            let ok = try await webView.callAsyncJavaScript(NativeCatalogBridge.review, arguments: ["appID": app.id], in: nil, contentWorld: .page) as? Bool
            if ok != true { error = "This catalog entry changed. Search for it in the server view." }
        } catch { self.error = "Could not open the server's app details." }
    }
    func stop() { connectionRevision = UUID(); connectionTask?.cancel(); connectionTask = nil; catalogDeadline?.cancel(); catalogRefreshing = false; timeout?.cancel(); answerDialog(false); webView.stopLoading(); loading = false }
    func answerDialog(_ accepted: Bool) {
        let pending = dialog; dialog = nil; pending?.complete(accepted)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard dialog == nil else { completionHandler(false); return }
        dialog = CatalogDialog(message: String(message.prefix(3000)), host: frame.securityOrigin.host, confirm: true, complete: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard dialog == nil else { completionHandler(); return }
        dialog = CatalogDialog(message: String(message.prefix(3000)), host: frame.securityOrigin.host, confirm: false, complete: { _ in completionHandler() })
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; error = nil
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.error = "The server is taking a while to respond. If an installation was submitted, check your Apps grid before retrying it."
            self?.loading = false // Do not cancel an installer or replay its POST.
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel(); loading = false; canGoBack = webView.canGoBack
        guard let url = webView.url else { return }
        host = url.host ?? ""
        if CatalogPolicy.sameOrigin(url, catalog), url.lastPathComponent.lowercased() == "login" { sawLogin = true; needsCatalogLogin = true; catalogLive = false; catalogRefreshing = false; catalogDeadline?.cancel() }
        if CatalogPolicy.returnAfterLogin(url, catalog: catalog, sawLogin: sawLogin) {
            sawLogin = false; webView.load(URLRequest(url: catalog))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        timeout?.cancel(); loading = false; catalogRefreshing = false; catalogDeadline?.cancel()
        if (error as NSError).code != NSURLErrorCancelled { self.error = "Could not load the server App Store (\((error as NSError).code)). Check the private connection. If you submitted an install, check your Apps grid before trying again." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, (url.scheme == "https" && url.user == nil && url.password == nil) || url.absoluteString == "about:blank" else {
            error = "The server App Store requires a secure HTTPS page."; decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil { webView.load(navigationAction.request) }
        return nil
    }
}
struct CatalogSurface: UIViewRepresentable {
    let model: CatalogBrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
struct UnraidAppStoreView: View {
    let server: ServerProfile
    @ObservedObject var model: CatalogBrowserModel
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).accessibilityLabel("Back in App Store")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Community Applications").font(.subheadline.bold())
                    Text(model.host.isEmpty ? server.name : model.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.openCatalog() } label: { Image(systemName: "house") }.accessibilityLabel("Open app catalog")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Text("Sign in to your server if prompted, then choose an app and review its installation settings. When finished, close the App Store to refresh your apps.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            if model.loading { ProgressView().frame(maxWidth: .infinity) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20) }
            CatalogSurface(model: model).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)).padding(.horizontal, 8)
        }.background { AsterBackdrop() }
        .onDisappear { model.stop() }
        .alert(model.dialog?.host ?? "Server", isPresented: Binding(get: { model.dialog != nil }, set: { if !$0 { model.answerDialog(false) } })) {
            if model.dialog?.confirm == true {
                Button("Continue") { model.answerDialog(true) }
                Button("Cancel", role: .cancel) { model.answerDialog(false) }
            } else { Button("OK") { model.answerDialog(true) } }
        } message: { Text(model.dialog?.message ?? "") }
    }
}

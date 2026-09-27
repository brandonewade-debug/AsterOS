import SwiftUI
import WebKit
import Combine

struct ContainerEditorTarget: Identifiable {
    let container: Container
    let server: ServerProfile
    var id: String { server.id.uuidString + ":" + container.id }
}
enum ContainerEditorBridge {
    // Use Unraid's own edit action to resolve the saved template, including custom names.
    static let open = #"""
    const entry = Array.from(document.querySelectorAll('a.exec[onclick]')).find(el =>
        (el.getAttribute('onclick') || '').trim().startsWith('editContainer(') && el.textContent.trim() === containerName);
    if (!entry) return false;
    entry.click(); return true;
    """#
    static let state = #"""
    const toggle = document.querySelector('input.advancedview[type="checkbox"]');
    return document.querySelector('#formTemplate') && toggle ? {advanced: toggle.checked} : null;
    """#
    static let setAdvanced = #"""
    const toggle = document.querySelector('input.advancedview[type="checkbox"]');
    if (!document.querySelector('#formTemplate') || !toggle || toggle.disabled) return false;
    if (toggle.checked !== advanced) toggle.click();
    return toggle.checked === advanced;
    """#
}
struct ContainerEditorView: View {
    let target: ContainerEditorTarget
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CatalogBrowserModel
    @State private var signIn = false
    @State private var closeEditor = false
    init(target: ContainerEditorTarget) {
        self.target = target
        _model = StateObject(wrappedValue: CatalogBrowserModel(server: target.server.address, serverID: target.server.id, editingContainer: target.container.name))
    }
    var body: some View {
        NavigationStack {
            ZStack {
                if !signIn { CatalogSurface(model: model).opacity(0).allowsHitTesting(false).accessibilityHidden(true) }
                if model.needsCatalogLogin {
                    GlassForm { Section { Text("Your server session needs to be renewed."); Button("Sign in to server") { signIn = true } } }
                } else { NativeContainerForm(model: model) }
            }
                .navigationTitle("Edit " + target.container.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { if model.nativeEditor != nil { closeEditor = true } else { dismiss() } }.disabled(model.applyingConfiguration) } }
                .confirmationDialog("Close without applying?", isPresented: $closeEditor, titleVisibility: .visible) { Button("Discard unapplied changes", role: .destructive) { dismiss() } }
                .sheet(isPresented: $signIn) { NavigationStack { UnraidAppStoreView(server: target.server, model: model).toolbar { Button("Done") { signIn = false } } } }
                .onChange(of: model.nativeEditor != nil) { _, ready in if ready { signIn = false } }
                .interactiveDismissDisabled(model.applyingConfiguration)
                .onAppear { model.resumeCatalog() }
                .onDisappear { model.stopCatalogObservation(); model.stop() }
        }
    }
}
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
                    Text("The Docker image, mounted shares, volumes and app-data folders are kept. You can reinstall later from Discover.").foregroundStyle(.secondary)
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
    let editingContainer: String?
    var startPage: URL { editingContainer == nil ? catalog : catalog.deletingLastPathComponent().appendingPathComponent("Docker") }
    @Published private(set) var editorAdvanced: Bool?
    @Published private(set) var changingEditorMode = false
    @Published private(set) var nativeEditor: EditorForm?
    @Published private(set) var editingConfiguration = false
    @Published private(set) var applyingConfiguration = false
    @Published private(set) var configurationResult: String?
    private var editorOpened = false
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
    init(server: URL, serverID: UUID, editingContainer: String? = nil) {
        self.editingContainer = editingContainer
        self.serverID = serverID
        catalog = CatalogPolicy.url(server: server)
        let config = WKWebViewConfiguration()
        // The server owns its login and install forms. No API keys or password scraping.
        config.websiteDataStore = CatalogSession.dataStore(serverID: serverID)
        session = ServerWebSession(serverID: serverID, server: server, dataStore: config.websiteDataStore)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780), configuration: config)
        super.init()
        if editingContainer == nil, let saved = CatalogCache.load(serverID: serverID, address: catalog) {
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
        guard !applyingConfiguration else { return }
        nativeEditor = nil; configurationResult = nil
        error = nil; loading = true; catalogLive = false; catalogRefreshing = true; needsCatalogLogin = false; cacheable = editingContainer == nil; editorOpened = false; editorAdvanced = nil
        catalogDeadline?.cancel()
        catalogDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !catalogLive else { return }
            catalogRefreshing = false
            error = editingContainer == nil ? "Your server is still preparing Community Applications. Retry or check the server view." : "The saved container template could not be opened yet. Check the server page; containers created outside Unraid may not have an editable template."
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
                webView.load(URLRequest(url: startPage))
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
                await self?.readEditorState()
                await self?.readNativeCatalog()
                do { try await Task.sleep(for: .milliseconds((self?.catalogLive == true || self?.nativeEditor != nil) ? 1500 : 300)) } catch { break }
            }
        }
    }
    func stopCatalogObservation() { catalogObservation?.cancel(); catalogObservation = nil }
    var onEditor: Bool {
        guard let url = webView.url, CatalogPolicy.sameOrigin(url, catalog) else { return false }
        let base = catalog.deletingLastPathComponent()
        return ["Docker/AddContainer", "Docker/UpdateContainer", "Apps/AddContainer", "Apps/UpdateContainer"].contains { base.appendingPathComponent($0).path == url.path }
    }
    private func readEditorState() async {
        guard let url = webView.url, CatalogPolicy.sameOrigin(url, catalog) else { editorAdvanced = nil; return }
        if onEditor {
            do {
                let state = try await webView.callAsyncJavaScript(ContainerEditorBridge.state, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                guard !Task.isCancelled, onEditor else { return }
                editorAdvanced = state?["advanced"] as? Bool
                if editorAdvanced != nil {
                    catalogDeadline?.cancel(); catalogRefreshing = false; needsCatalogLogin = false; sawLogin = false
                    if !editingConfiguration && !applyingConfiguration && configurationResult == nil { await refreshNativeEditor() }
                }
            } catch { editorAdvanced = nil }
        } else {
            editorAdvanced = nil
            if let editingContainer, !editorOpened, url.path == startPage.path {
                do {
                    let opened = try await webView.callAsyncJavaScript(ContainerEditorBridge.open, arguments: ["containerName": editingContainer], in: nil, contentWorld: .page) as? Bool
                    if opened == true { editorOpened = true }
                } catch { /* Keep the server's own Docker page usable. */ }
            }
        }
    }
    func setEditorAdvanced(_ advanced: Bool) async {
        guard onEditor, editorAdvanced != nil, !changingEditorMode, !editingConfiguration, !applyingConfiguration else { return }
        changingEditorMode = true
        defer { changingEditorMode = false }
        do {
            let changed = try await webView.callAsyncJavaScript(ContainerEditorBridge.setAdvanced, arguments: ["advanced": advanced], in: nil, contentWorld: .page) as? Bool
            if changed == true { editorAdvanced = advanced; await refreshNativeEditor() }
            else { error = "Use the server's Basic/Advanced View switch for this editor version." }
        } catch { self.error = "Could not change the editor view. Your form has not been submitted." }
    }
    func refreshNativeEditor() async {
        guard onEditor, !applyingConfiguration else { return }
        let unavailable = "This configuration form is not ready or is unsupported. Nothing has been submitted. Reopen the editor or use the server view."
        do {
            if let json = try await webView.callAsyncJavaScript(NativeEditorBridge.snapshot, arguments: [:], in: nil, contentWorld: .page) as? String,
               let data = json.data(using: .utf8), data.count < 2_000_000, onEditor, !applyingConfiguration, configurationResult == nil {
                nativeEditor = try JSONDecoder().decode(EditorForm.self, from: data)
                if error == unavailable { error = nil }
            } else if onEditor, !loading, !applyingConfiguration, configurationResult == nil {
                nativeEditor = nil
                error = unavailable
            }
        } catch { nativeEditor = nil; self.error = "Could not read the container configuration. Your settings have not been applied." }
    }
    @discardableResult func updateEditorField(_ field: EditorField, value: String = "", checked: Bool = false, values: [String] = []) async -> Bool {
        await mutateEditor(NativeEditorBridge.update, arguments: ["fieldID": field.id, "value": value, "checked": checked, "values": values])
    }
    func performEditorAction(_ action: EditorAction) async {
        _ = await mutateEditor(NativeEditorBridge.action, arguments: ["actionID": action.id])
    }
    private func mutateEditor(_ script: String, arguments: [String: Any]) async -> Bool {
        guard onEditor, !editingConfiguration, !applyingConfiguration else { return false }
        editingConfiguration = true; error = nil
        defer { editingConfiguration = false }
        do {
            guard let message = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page) as? String else { error = "The editor is no longer available. Reopen it before changing settings."; return false }
            guard message.isEmpty else { error = message; return false }
            await refreshNativeEditor()
            return true
        } catch { self.error = "Could not update this field. Your configuration has not been applied."; return false }
    }
    func applyEditorConfiguration() async {
        guard onEditor, nativeEditor != nil, !editingConfiguration, !applyingConfiguration else { return }
        applyingConfiguration = true; error = nil
        do {
            guard let message = try await webView.callAsyncJavaScript(NativeEditorBridge.apply, arguments: [:], in: nil, contentWorld: .page) as? String else {
                applyingConfiguration = false; error = "The configuration form is unavailable. Nothing was submitted."; return
            }
            if !message.isEmpty { applyingConfiguration = false; error = message }
        } catch {
            // Navigation may interrupt the bridge after submission. Never automatically retry.
            applyingConfiguration = false; nativeEditor = nil
            configurationResult = "The apply result could not be confirmed."
        }
    }
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
            if self?.applyingConfiguration == true {
                self?.applyingConfiguration = false; self?.nativeEditor = nil
                self?.configurationResult = "The server has not confirmed the result yet. Check the container before retrying."
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel(); loading = false; canGoBack = webView.canGoBack
        if applyingConfiguration {
            applyingConfiguration = false; nativeEditor = nil
            configurationResult = webView.url?.lastPathComponent.lowercased() == "login"
                ? "Your server sign-in expired during this request. The apply result is unknown. Renew access and check the container before retrying."
                : "Unraid finished responding to the configuration request. Verify the container in Apps."
        }
        guard let url = webView.url else { return }
        host = url.host ?? ""
        if CatalogPolicy.sameOrigin(url, catalog), url.lastPathComponent.lowercased() == "login" { sawLogin = true; editorOpened = false; needsCatalogLogin = true; catalogLive = false; catalogRefreshing = false; catalogDeadline?.cancel() }
        if CatalogPolicy.returnAfterLogin(url, catalog: catalog, sawLogin: sawLogin) {
            sawLogin = false; webView.load(URLRequest(url: startPage))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        timeout?.cancel(); loading = false; catalogRefreshing = false; catalogDeadline?.cancel()
        if applyingConfiguration && (error as NSError).code != NSURLErrorCancelled {
            applyingConfiguration = false; nativeEditor = nil; configurationResult = "The apply result could not be confirmed."
        }
        if (error as NSError).code != NSURLErrorCancelled { self.error = "Could not load Discover (\((error as NSError).code)). Check the private connection. If you submitted an install, check your Apps grid before trying again." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, (url.scheme == "https" && url.user == nil && url.password == nil) || url.absoluteString == "about:blank" else {
            error = "Discover requires a secure HTTPS page."; decisionHandler(.cancel); return
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
                    Text(model.editingContainer == nil ? "Community Applications" : "Container configuration").font(.subheadline.bold())
                    Text(model.host.isEmpty ? server.name : model.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.openCatalog() } label: { Image(systemName: "house") }.accessibilityLabel(model.editingContainer == nil ? "Open app catalog" : "Reopen container editor")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Text(model.editingContainer == nil ? "Review the template settings before pressing Apply to install. Advanced mode shows additional Docker options." : "Edit your saved template, then press Apply on the server form. Applying changes may recreate or restart this container.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            if let advanced = model.editorAdvanced {
                Toggle("Advanced mode", isOn: Binding(get: { model.editorAdvanced ?? advanced }, set: { value in Task { await model.setEditorAdvanced(value) } }))
                    .disabled(model.changingEditorMode).padding(.horizontal, 20)
            }
            if model.loading || (model.editingContainer != nil && model.editorAdvanced == nil && !model.needsCatalogLogin && model.error == nil) { ProgressView("Opening configuration…").frame(maxWidth: .infinity) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20) }
            CatalogSurface(model: model).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)).padding(.horizontal, 8)
        }.background { AsterBackdrop() }
        .alert(model.dialog?.host ?? "Server", isPresented: Binding(get: { model.dialog != nil }, set: { if !$0 { model.answerDialog(false) } })) {
            if model.dialog?.confirm == true {
                Button("Continue") { model.answerDialog(true) }
                Button("Cancel", role: .cancel) { model.answerDialog(false) }
            } else { Button("OK") { model.answerDialog(true) } }
        } message: { Text(model.dialog?.message ?? "") }
    }
}

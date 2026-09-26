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
struct CatalogDialog {
    let message: String
    let host: String
    let confirm: Bool
    let complete: (Bool) -> Void
}
@MainActor final class CatalogBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let catalog: URL
    @Published var loading = false
    @Published var error: String?
    @Published var dialog: CatalogDialog?
    @Published var canGoBack = false
    @Published var host = ""
    private var observer: AnyCancellable?
    private var sawLogin = false
    private var timeout: Task<Void, Never>?
    init(server: URL) {
        catalog = CatalogPolicy.url(server: server)
        let config = WKWebViewConfiguration()
        // The server owns its login and install forms. No API keys or password scraping.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observer = TailnetStore.shared.$revision.dropFirst().sink { [weak self] _ in
            self?.webView.configuration.websiteDataStore.proxyConfigurations = TailnetStore.shared.proxies
        }
        openCatalog()
    }
    func openCatalog() {
        error = nil; loading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let proxies = try await TailnetStore.shared.prepare(for: catalog.host)
                webView.configuration.websiteDataStore.proxyConfigurations = proxies
                webView.load(URLRequest(url: catalog))
            } catch { self.error = error.localizedDescription; self.loading = false }
        }
    }
    func stop() { timeout?.cancel(); answerDialog(false); webView.stopLoading(); loading = false }
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
            self?.error = "The server is taking a while to respond. If an installation was submitted, check Installed before retrying it."
            self?.loading = false // Do not cancel an installer or replay its POST.
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel(); loading = false; canGoBack = webView.canGoBack
        guard let url = webView.url else { return }
        host = url.host ?? ""
        if CatalogPolicy.sameOrigin(url, catalog), url.lastPathComponent.lowercased() == "login" { sawLogin = true }
        if CatalogPolicy.returnAfterLogin(url, catalog: catalog, sawLogin: sawLogin) {
            sawLogin = false; webView.load(URLRequest(url: catalog))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        timeout?.cancel(); loading = false
        if (error as NSError).code != NSURLErrorCancelled { self.error = "Could not load the server App Store (\((error as NSError).code)). Check the private connection. If you submitted an install, check Installed before trying again." }
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
            Text("Sign in to your server if prompted, then choose an app and review its installation settings. When finished, switch to Installed to refresh your apps.")
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

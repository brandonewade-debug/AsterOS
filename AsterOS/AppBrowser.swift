import SwiftUI
import WebKit
import Combine

@MainActor final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var routeObserver: AnyCancellable?
    @Published var title = ""
    @Published var host = ""
    @Published var back = false
    @Published var forward = false
    @Published var loading = false
    @Published var error: String?
    init(url: URL) {
        let config = WKWebViewConfiguration()
        // Separate ephemeral website session per launch; no API authentication headers.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        routeObserver = TailnetStore.shared.$revision.dropFirst().sink { [weak self] _ in
            self?.webView.configuration.websiteDataStore.proxyConfigurations = TailnetStore.shared.proxies
        }
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let proxies = try await TailnetStore.shared.prepare(for: url.host)
                self.webView.configuration.websiteDataStore.proxyConfigurations = proxies
                self.webView.load(URLRequest(url: url))
            } catch { self.error = error.localizedDescription; self.loading = false }
        }
    }
    private func sync() {
        title = webView.title ?? "App"
        host = webView.url?.host ?? ""
        back = webView.canGoBack; forward = webView.canGoForward; loading = webView.isLoading
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { error = nil; loading = true; sync() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription; loading = false; sync() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription; loading = false; sync() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if AppWebPolicy.allows(url) || url.absoluteString == "about:blank" { decisionHandler(.allow) }
        else { error = "This app link is not a supported HTTP or HTTPS address."; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, AppWebPolicy.allows(url) { webView.load(navigationAction.request) }
        return nil
    }
}
struct BrowserSurface: UIViewRepresentable {
    let model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
struct AppBrowser: View {
    let app: SavedApp
    @StateObject private var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    init(app: SavedApp) { self.app = app; _model = StateObject(wrappedValue: BrowserModel(url: app.url)) }
    var body: some View {
        BrowserSurface(model: model)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Label(app.name, systemImage: app.symbol).font(.headline)
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Close app")
                    }
                    HStack(spacing: 20) {
                        Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.back).accessibilityLabel("Back")
                        Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.forward).accessibilityLabel("Forward")
                        Text(model.host).font(.caption).lineLimit(1).frame(maxWidth: .infinity)
                        Button { openURL(model.webView.url ?? app.url) } label: { Image(systemName: "safari") }.accessibilityLabel("Open in Safari")
                        Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                    }
                }.padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28)).padding(10)
            }
    }
}

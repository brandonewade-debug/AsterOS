import SwiftUI
import WebKit
import Combine

// The callback is intercepted locally, before WebKit sends it to the server.
// No API key, password, or browser cookie is sent to an AsterOS cloud service.
struct UnraidAuthorization: Identifiable {
    let id = UUID()
    let server: URL
    let state = UUID().uuidString + UUID().uuidString
    let created = Date()
    let allowDockerManagement: Bool
    var callback: URL { server.appendingPathComponent("asteros-authorization/\(id.uuidString)/callback") }
    init(address: String, allowDockerManagement: Bool) throws {
        var url = try AddressPolicy.validate(address)
        if url.lastPathComponent == "graphql" { url.deleteLastPathComponent() }
        server = url
        self.allowDockerManagement = allowDockerManagement
    }
    func authorizationURL(automaticReturn: Bool = true) -> URL {
        var components = URLComponents(url: server.appendingPathComponent("ApiKeyAuthorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: "AsterOS"),
            URLQueryItem(name: "description", value: "View your server dashboard" + (allowDockerManagement ? " and create, start, stop, update, or remove Docker containers." : ".")),
            URLQueryItem(name: "scopes", value: allowDockerManagement ? "role:viewer,docker:read,docker:create,docker:update,docker:delete" : "role:viewer")
        ]
        if automaticReturn {
            components.queryItems! += [URLQueryItem(name: "redirect_uri", value: callback.absoluteString), URLQueryItem(name: "state", value: state)]
        }
        return components.url!
    }
    func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == callback.host?.lowercased()
        && (url.port ?? 443) == (callback.port ?? 443) && url.path == callback.path
        && url.user == nil && url.password == nil
    }
    func isPostLoginLanding(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == server.host?.lowercased(),
              (url.port ?? 443) == (server.port ?? 443), url.user == nil, url.password == nil else { return false }
        let base = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = base.isEmpty ? "" : "/" + base
        return [prefix + "/Main", prefix + "/Dashboard"].contains(url.path)
    }
    func key(from url: URL, now: Date = Date()) throws -> String {
        guard isCallback(url), url.fragment == nil, now.timeIntervalSince(created) < 600 else {
            throw AppError.message("The sign-in response is invalid or expired. Please try again.")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let keys = items.filter { $0.name == "api_key" }
        guard states.count == 1, states.first?.value == state,
              keys.count == 1, let key = keys.first?.value, !key.isEmpty, key.count <= 8192,
              key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AppError.message("Authorization was not completed or the response could not be verified.")
        }
        return key
    }
}

@MainActor final class UnraidSignInModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let request: UnraidAuthorization
    let webView: WKWebView
    private var routeObserver: AnyCancellable?
    @Published var error: String?
    @Published var loading = true
    @Published var host: String
    @Published var authorizedKey: String?
    private var completed = false
    private var resumedAfterLogin = false
    init(request: UnraidAuthorization) {
        self.request = request
        host = request.server.host ?? "Unraid"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        routeObserver = TailnetStore.shared.$revision.dropFirst().sink { [weak self] _ in
            self?.webView.configuration.websiteDataStore.proxyConfigurations = TailnetStore.shared.proxies
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task { [weak self] in
            guard let self else { return }
            do {
                let proxies = try await TailnetStore.shared.prepare(for: request.authorizationURL().host)
                self.webView.configuration.websiteDataStore.proxyConfigurations = proxies
                self.webView.load(URLRequest(url: request.authorizationURL()))
            } catch { self.error = error.localizedDescription; self.loading = false }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !completed, let url = action.request.url else { decisionHandler(.cancel); return }
        let containsKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "api_key" } == true
        if request.isCallback(url) || containsKey {
            // Always cancel credential-bearing navigations, even an invalid callback.
            decisionHandler(.cancel)
            do {
                guard action.targetFrame?.isMainFrame == true else { throw AppError.message("Unexpected sign-in response. Please try again.") }
                let key = try request.key(from: url)
                completed = true; loading = false; authorizedKey = key
            } catch { self.error = error.localizedDescription; loading = false }
            return
        }
        guard url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank" else {
            error = "Sign-in requires HTTPS. External identity providers may require the Safari option below."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        host = webView.url?.host ?? request.server.host ?? "Unraid"
        // Main may keep streaming resources open, so do not wait for didFinish.
        resumeAfterLogin()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        resumeAfterLogin()
    }
    private func resumeAfterLogin() {
        if !completed, !resumedAfterLogin, let url = webView.url, request.isPostLoginLanding(url) {
            resumedAfterLogin = true
            DispatchQueue.main.async { [weak self] in self?.continueToApproval() }
        }
    }
    func continueToApproval() {
        guard !completed else { return }
        error = nil; loading = true
        webView.load(URLRequest(url: request.authorizationURL()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, !completed else { return }
        loading = false
        // Do not echo failing URLs: an authorization URL can contain a key.
        self.error = "Could not load the secure sign-in page. Check connectivity and the server certificate, or use Safari."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, url.scheme == "https" { webView.load(action.request) }
        return nil
    }
}

private struct SignInSurface: UIViewRepresentable {
    let model: UnraidSignInModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }
}

struct UnraidSignInView: View {
    @StateObject private var model: UnraidSignInModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let receiveKey: (String) -> Void
    init(request: UnraidAuthorization, receiveKey: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: UnraidSignInModel(request: request))
        self.receiveKey = receiveKey
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Label(model.host, systemImage: "lock.fill").font(.caption).padding(10)
                if model.loading { ProgressView().padding(8) }
                SignInSurface(model: model)
                VStack(alignment: .leading, spacing: 10) {
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                    Text("Sign in on your server, then approve AsterOS. Your password stays in the server’s sign-in page.")
                    Button("Continue to approval") { model.continueToApproval() }
                    if TailnetStore.shared.enabled && TailnetPolicy.contains(model.request.server.host ?? "") {
                        Text("Stay in AsterOS to use its private connection. Safari does not share this connection.").foregroundStyle(.secondary)
                    } else {
                        Button("Use Safari instead") { openURL(model.request.authorizationURL(automaticReturn: false)) }
                    }
                    Text("In Safari, approve access, copy the generated key, then return to AsterOS and paste it. Website logins do not unlock native API requests through Cloudflare or Organizr.").foregroundStyle(.secondary)
                }.font(.caption).padding().background(DockTheme.card)
            }
            .navigationTitle("Sign in to Unraid").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: model.authorizedKey) { _, value in if let value { receiveKey(value); model.authorizedKey = nil } }
        }
    }
}

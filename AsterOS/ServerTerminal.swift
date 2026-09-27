import SwiftUI
import WebKit
import Combine

// Only the selected server may receive terminal input. No API keys enter WebKit.
enum TerminalPolicy {
    static func base(_ server: URL) -> URL { CatalogPolicy.url(server: server).deletingLastPathComponent() }
    static func terminal(_ server: URL) -> URL { base(server).appendingPathComponent("webterminal/ttyd/") }
    static func allows(_ url: URL, server: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && CatalogPolicy.sameOrigin(url, server)
    }
    static func commanderCommand(nonce: String) -> String? {
        guard UUID(uuidString: nonce) != nil else { return nil }
        // Foreground process, scoped to this terminal. Never kill other agents or install a boot service.
        let script = #"trap 'printf "\nASTEROS_DC_END_\#(nonce)\n"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP; printf "\nASTEROS_DC_BEGIN_\#(nonce)\n"; if ! command -v node >/dev/null 2>&1; then printf "Node.js is required on this server.\n"; exit 127; fi; aster_dc_dir=/mnt/user/appdata/asteros/desktop-commander; aster_dc_entry="$aster_dc_dir/node_modules/@wonderwhy-er/desktop-commander/dist/index.js"; if [ -f "$aster_dc_dir/.installed-0.2.51" ] && [ -f "$aster_dc_entry" ]; then printf "Reconnecting with installed Desktop Commander.\n"; node "$aster_dc_entry" remote; elif command -v desktop-commander >/dev/null 2>&1; then printf "Reconnecting with existing Desktop Commander.\n"; desktop-commander remote; else if [ ! -d /mnt/user/appdata ]; then printf "The appdata share must be available before installing Desktop Commander.\n"; exit 1; fi; if ! command -v npm >/dev/null 2>&1; then printf "npm is required for the one-time installation.\n"; exit 127; fi; mkdir -p "$aster_dc_dir" || exit 1; if ! mkdir "$aster_dc_dir/.installing" 2>/dev/null; then printf "Another installation is running, or a previous installation was interrupted. Check the installation before retrying.\n"; exit 1; fi; trap 'rmdir "$aster_dc_dir/.installing" 2>/dev/null; printf "\nASTEROS_DC_END_\#(nonce)\n"' EXIT; printf "Installing Desktop Commander once in appdata…\n"; npm install --prefix "$aster_dc_dir" --no-audit --no-fund --save-exact @wonderwhy-er/desktop-commander@0.2.51 && [ -f "$aster_dc_entry" ] || exit 1; touch "$aster_dc_dir/.installed-0.2.51" || exit 1; rmdir "$aster_dc_dir/.installing" || exit 1; printf "Installation saved. Connecting Desktop Commander.\n"; node "$aster_dc_entry" remote; fi"#
        return "bash -c '" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
enum TerminalBridge {
    static let observeSocket = #"""
    if (location.pathname.includes('/webterminal/ttyd/')) {
      const OriginalSocket = window.WebSocket;
      window.WebSocket = class extends OriginalSocket {
        constructor(...args) {
          super(...args);
          const url = new URL(args[0], location.href);
          if (url.host === location.host && url.pathname.startsWith(location.pathname)) window.asterTerminalSocket = this;
        }
      };
    }
    """#
    static let start = #"""
    const term = window.term;
    if (!term || typeof term.input !== 'function' || window.asterTerminalSocket?.readyState !== 1) return false;
    const line = term.buffer.active.getLine(term.buffer.active.baseY + term.buffer.active.cursorY)?.translateToString(true) || '';
    if (!/[#$]\s*$/.test(line)) return false;
    window.asterCommander = {nonce, state:'requested'};
    term.input(command + '\r', true); return true;
    """#
    static let status = #"""
    const term = window.term;
    if (!term || typeof term.input !== 'function') return JSON.stringify({ready:false,state:'idle'});
    const session = window.asterCommander;
    if (window.asterTerminalSocket?.readyState !== 1) return JSON.stringify({ready:false,state:session && session.state !== 'stopped' ? 'unknown' : 'idle'});
    if (session) {
      const buffer = term.buffer.active;
      const lines = []; let logical = '';
      for (let i = Math.max(0,buffer.length-400); i < buffer.length; i++) {
        const row = buffer.getLine(i);
        if (!row?.isWrapped && logical) { lines.push(logical.trim()); logical = ''; }
        logical += row?.translateToString(false) || '';
      }
      if (logical) lines.push(logical.trim());
      for (const line of lines) {
        if (line === 'ASTEROS_DC_BEGIN_' + session.nonce && session.state === 'requested') session.state = 'starting';
        if (session.state === 'starting' && /device ready/i.test(line)) session.state = 'running';
        if (line === 'ASTEROS_DC_END_' + session.nonce) session.state = 'stopped';
      }
    }
    return JSON.stringify({ready:true,state:session?.state || 'idle'});
    """#
    static let interrupt = #"""
    if (!window.term || typeof window.term.input !== 'function' || window.asterTerminalSocket?.readyState !== 1) return false;
    window.term.input('\x03', true); return true;
    """#
}
@MainActor final class ServerTerminalModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let server: ServerProfile
    let webView: WKWebView
    private let session: ServerWebSession
    private var observer: AnyCancellable?
    private var poll: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var opening = false
    @Published private(set) var ready = false
    @Published private(set) var signingIn = false
    @Published private(set) var terminalVisible = false
    @Published private(set) var loading = true
    @Published private(set) var commanderState = "idle"
    @Published var error: String?
    var agentMayBeRunning: Bool { ["requested", "starting", "running", "stopping", "unknown"].contains(commanderState) }
    var statusText: String {
        switch commanderState {
        case "requested": return "Start requested"
        case "starting": return "Starting · check terminal for pairing"
        case "running": return "Device ready"
        case "stopping": return "Stop requested · waiting for exit"
        case "stopped": return "Agent exited"
        case "unknown": return "Connection lost · agent status unknown"
        default: return ready ? "Ready to start" : "Connecting to server…"
        }
    }
    init(server: ServerProfile) {
        self.server = server
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: TerminalBridge.observeSocket, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = CatalogSession.dataStore(serverID: server.id)
        session = ServerWebSession(serverID: server.id, server: server.address, dataStore: config.websiteDataStore)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780), configuration: config)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.isOpaque = false; webView.backgroundColor = .black
        observer = TailnetStore.shared.$revision.dropFirst().sink { [weak self] _ in self?.webView.configuration.websiteDataStore.proxyConfigurations = TailnetStore.shared.proxies }
    }
    var onTerminal: Bool { webView.url.map { TerminalPolicy.allows($0, server: server.address) && $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == TerminalPolicy.terminal(server.address).path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? false }
    func connect() {
        guard connection == nil, !agentMayBeRunning else { return }
        loading = true; error = nil
        connection = Task { [weak self] in
            guard let self else { return }
            defer { connection = nil }
            do {
                try await session.restore()
                webView.configuration.websiteDataStore.proxyConfigurations = try await TailnetStore.shared.prepare(for: server.address.host)
                try Task.checkCancellation()
                webView.load(URLRequest(url: TerminalPolicy.base(server.address).appendingPathComponent("Dashboard")))
            } catch { self.error = "Could not connect to your server. Check the private connection."; loading = false }
        }
        if poll == nil {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.readStatus()
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
        }
    }
    private func readStatus() async {
        guard onTerminal else { return }
        do {
            let raw = try await webView.callAsyncJavaScript(TerminalBridge.status, arguments: [:], in: nil, contentWorld: .page) as? String
            guard onTerminal, let data = raw?.data(using: .utf8), let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            ready = state["ready"] as? Bool == true
            if ready { loading = false }
            if let value = state["state"] as? String, !(commanderState == "stopping" && ["requested", "starting", "running"].contains(value)) { commanderState = value }
        } catch { ready = false; if agentMayBeRunning { commanderState = "unknown" } }
    }
    func startCommander() async {
        guard ready, onTerminal, !agentMayBeRunning else { return }
        let nonce = UUID().uuidString
        guard let command = TerminalPolicy.commanderCommand(nonce: nonce) else { return }
        do {
            let sent = try await webView.callAsyncJavaScript(TerminalBridge.start, arguments: ["nonce": nonce, "command": command], in: nil, contentWorld: .page) as? Bool
            if sent == true { commanderState = "requested"; error = nil }
            else { error = "Wait for the server shell prompt before starting Desktop Commander. This terminal version may not support the shortcut." }
        } catch { commanderState = "unknown"; self.error = "Could not confirm whether the command was sent. Check the terminal before retrying." }
    }
    func interrupt() async {
        guard ready, onTerminal else { return }
        do {
            let sent = try await webView.callAsyncJavaScript(TerminalBridge.interrupt, arguments: [:], in: nil, contentWorld: .page) as? Bool
            if sent == true, agentMayBeRunning { commanderState = "stopping" }
            if sent != true { error = "Use Ctrl+C in the terminal to interrupt the foreground command." }
        } catch { self.error = "The interrupt could not be confirmed. Check the terminal." }
    }
    func sendKey(_ key: String) async {
        guard ready, onTerminal, ["\t", "\u{1b}", "\r", "\u{1b}[A", "\u{1b}[B"].contains(key) else { return }
        _ = try? await webView.callAsyncJavaScript("if (!window.term?.input) return false; window.term.input(key, true); window.term.focus(); return true;", arguments: ["key": key], in: nil, contentWorld: .page)
    }
    private func openTerminal() async {
        guard !opening, !onTerminal, !signingIn else { return }
        opening = true; defer { opening = false }
        do {
            let endpoint = TerminalPolicy.base(server.address).appendingPathComponent("webGui/include/OpenTerminal.php").absoluteString
            let ok = try await webView.callAsyncJavaScript("const url = new URL(endpoint); url.searchParams.set('tag','ttyd'); const r = await fetch(url, {credentials:'same-origin',redirect:'error'}); return r.ok;", arguments: ["endpoint": endpoint], in: nil, contentWorld: .page) as? Bool
            guard ok == true else { error = "The server did not open a terminal. Check that your web session has administrator access."; loading = false; return }
            try await Task.sleep(for: .milliseconds(250))
            webView.load(URLRequest(url: TerminalPolicy.terminal(server.address)))
        } catch { self.error = "Could not open the server terminal. Try reconnecting."; loading = false }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, TerminalPolicy.allows(url, server: server.address) else { return }
        signingIn = url.lastPathComponent.lowercased() == "login"
        if signingIn { loading = false; return }
        if onTerminal { terminalVisible = true; loading = false; Task { await readStatus() } }
        else { Task { await openTerminal() } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.navigationType == .linkActivated, url.scheme == "https", url.user == nil, url.password == nil, !TerminalPolicy.allows(url, server: server.address) {
            UIApplication.shared.open(url); decisionHandler(.cancel); return
        }
        guard let url = action.request.url, TerminalPolicy.allows(url, server: server.address) else { error = "Terminal navigation must stay on your server. Open Desktop Commander pairing in your browser."; decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false; ready = false; self.error = "Terminal disconnected. Check your private connection."
        if agentMayBeRunning { commanderState = "unknown" }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "https", url.user == nil, url.password == nil { UIApplication.shared.open(url) }
        return nil
    }
    func close() {
        connection?.cancel(); connection = nil; poll?.cancel(); poll = nil
        session.stopObserving(); webView.navigationDelegate = nil; webView.uiDelegate = nil; webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
    }
}
struct ServerTerminalSurface: UIViewRepresentable {
    let model: ServerTerminalModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
struct ServerTerminalView: View {
    let commander: Bool
    @StateObject private var model: ServerTerminalModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStart = false
    @State private var confirmClose = false
    init(server: ServerProfile, commander: Bool = false) {
        self.commander = commander
        _model = StateObject(wrappedValue: ServerTerminalModel(server: server))
    }
    var body: some View {
        VStack(spacing: 12) {
            if commander {
                HStack {
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.agentMayBeRunning { Button("Stop") { Task { await model.interrupt() } }.disabled(!model.ready) }
                    else { Button("Start") { confirmStart = true }.disabled(!model.ready) }
                }.padding(.horizontal)
                Text("Start reuses the installed copy. On first use, it installs once in your appdata share. Pair only if Desktop Commander asks. Stop interrupts the agent started in this session; it does not stop agents launched elsewhere.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if model.loading { ProgressView("Opening terminal…") }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                if !model.agentMayBeRunning { Button("Reconnect") { model.connect() } }
            }
            if model.signingIn { Text("Sign in to your server to open its terminal.").font(.caption) }
            ServerTerminalSurface(model: model)
                .opacity(model.terminalVisible || model.signingIn ? 1 : 0)
            if !commander {
                HStack {
                    Button("Ctrl+C") { Task { await model.interrupt() } }
                    Button("Tab") { Task { await model.sendKey("\t") } }
                    Button("Esc") { Task { await model.sendKey("\u{1b}") } }
                    Button { Task { await model.sendKey("\u{1b}[A") } } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Previous command")
                    Button("Return") { Task { await model.sendKey("\r") } }
                }.font(.caption).disabled(!model.ready).padding(.bottom, 8)
            }
        }.background { AsterBackdrop() }
        .navigationTitle(commander ? "Desktop Commander" : "Terminal").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.agentMayBeRunning)
        .toolbar { if model.agentMayBeRunning { ToolbarItem(placement: .cancellationAction) { Button("Close") { confirmClose = true } } } }
        .confirmationDialog("Start Desktop Commander on this server?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start Desktop Commander") { Task { await model.startCommander() } }
        } message: { Text("Reconnect using the installed Desktop Commander. If no copy is available, AsterOS installs version 0.2.51 once in appdata. Your paired AI clients get the terminal user’s permissions. Node.js is required; npm is needed only for installation.") }
        .confirmationDialog("Close this terminal?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Stop first") { Task { await model.interrupt() } }
            Button("Close without confirming stop", role: .destructive) { dismiss() }
        } message: { Text("Closing or backgrounding a terminal does not confirm the agent stopped. Use Stop and wait for Agent exited to verify. Long-running remote support is not guaranteed when iOS suspends AsterOS.") }
        .task { model.connect() }
        .onDisappear { model.close() }
    }
}

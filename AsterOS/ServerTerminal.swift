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
    static func attachCommand(sessionID: UUID) -> String {
        let name = "asteros-" + sessionID.uuidString.lowercased()
        return "if command -v tmux >/dev/null 2>&1; then if (tmux -L asteros -f /dev/null has-session -t " + name + " 2>/dev/null || tmux -L asteros -f /dev/null new-session -d -s " + name + " 'exec bash --login'); then printf '\\nASTEROS_PERSIST_" + name + "\\n'; tmux -L asteros set-option -t " + name + " status off; tmux -L asteros attach-session -t " + name + "; else printf '\\nASTEROS_NO_TMUX_" + name + "\\n'; fi; else printf '\\nASTEROS_NO_TMUX_" + name + "\\n'; fi"
    }
    static func commanderCommand(nonce: String) -> String? {
        guard UUID(uuidString: nonce) != nil else { return nil }
        // Foreground process, scoped to this terminal. Never kill other agents or install a boot service.
        let script = #"trap 'printf "\nASTEROS_DC_END_\#(nonce)\n"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP; printf "\nASTEROS_DC_BEGIN_\#(nonce)\n"; if ! command -v node >/dev/null 2>&1; then printf "Node.js is required on this server.\n"; exit 127; fi; aster_dc_dir=/mnt/user/appdata/asteros/desktop-commander; aster_dc_entry="$aster_dc_dir/node_modules/@wonderwhy-er/desktop-commander/dist/index.js"; if [ -f "$aster_dc_dir/.installed-0.2.51" ] && [ -f "$aster_dc_entry" ]; then printf "Reconnecting with installed Desktop Commander.\n"; node "$aster_dc_entry" remote; elif command -v desktop-commander >/dev/null 2>&1; then printf "Reconnecting with existing Desktop Commander.\n"; desktop-commander remote; else if [ ! -d /mnt/user/appdata ]; then printf "The appdata share must be available before installing Desktop Commander.\n"; exit 1; fi; if ! command -v npm >/dev/null 2>&1; then printf "npm is required for the one-time installation.\n"; exit 127; fi; mkdir -p "$aster_dc_dir" || exit 1; if ! mkdir "$aster_dc_dir/.installing" 2>/dev/null; then printf "Another installation is running, or a previous installation was interrupted. Check the installation before retrying.\n"; exit 1; fi; trap 'rmdir "$aster_dc_dir/.installing" 2>/dev/null; printf "\nASTEROS_DC_END_\#(nonce)\n"' EXIT; printf "Installing Desktop Commander once in appdata…\n"; npm install --prefix "$aster_dc_dir" --no-audit --no-fund --save-exact @wonderwhy-er/desktop-commander@0.2.51 && [ -f "$aster_dc_entry" ] || exit 1; touch "$aster_dc_dir/.installed-0.2.51" || exit 1; rmdir "$aster_dc_dir/.installing" || exit 1; printf "Installation saved. Connecting Desktop Commander.\n"; node "$aster_dc_entry" remote; fi"#
        return "bash -c '" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
enum TerminalBridge {
    static let attach = #"""
    const term = window.term;
    if (!term?.input || window.asterTerminalSocket?.readyState !== 1) return 'waiting';
    if (window.asterAttachSent) return window.asterPersistence || 'attaching';
    const line = term.buffer.active.getLine(term.buffer.active.baseY + term.buffer.active.cursorY)?.translateToString(true) || '';
    if (!/[#$]\s*$/.test(line)) return 'waiting';
    window.asterSessionName = sessionName;
    window.asterAttachSent = true; window.asterPersistence = 'attaching';
    let output = '';
    const listener = term.onWriteParsed(() => {
      const buffer = term.buffer.active;
      output = '';
      for(let i = Math.max(0,buffer.length-100); i < buffer.length; i++) {
        const row = buffer.getLine(i);
        if (!row?.isWrapped) output += '\n';
        output += row?.translateToString(false) || '';
      }
      if (output.split('\n').some(line => line.trim() === 'ASTEROS_PERSIST_' + sessionName)) window.asterPersistence = 'persistent';
      if (output.split('\n').some(line => line.trim() === 'ASTEROS_NO_TMUX_' + sessionName)) window.asterPersistence = 'unavailable';
      if (window.asterPersistence !== 'attaching') listener.dispose();
    });
    term.input(command + '\r', true); return 'attaching';
    """#
    static let appearance = #"""
    let viewport = document.querySelector('meta[name="viewport"]');
    if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; document.head.appendChild(viewport); }
    viewport.content = 'width=device-width, initial-scale=1, viewport-fit=cover';
    if (!document.getElementById('aster-terminal-style')) {
      const style = document.createElement('style'); style.id = 'aster-terminal-style';
      style.textContent = 'html,body{margin:0;width:100%;height:100%;background:#101217;overflow:hidden}#terminal{box-sizing:border-box;width:100%;height:100%;padding:10px}.xterm-viewport{scrollbar-width:thin}';
      document.head.appendChild(style);
    }
    const term = window.term;
    if (!term) return false;
    if (term.options.fontSize !== fontSize || term.options.theme?.background !== '#101217') {
      term.options.fontSize = fontSize;
      term.options.fontFamily = 'ui-monospace, Menlo, monospace';
      term.options.lineHeight = 1.2;
      term.options.cursorBlink = true;
      term.options.theme = {...term.options.theme,background:'#101217',foreground:'#e8edf2',cursor:'#27dbc9',selectionBackground:'#245651'};
      if (typeof term.fit === 'function') requestAnimationFrame(() => term.fit());
    }
    if (!window.asterTerminalResize) {
      const fit = () => { if (typeof window.term?.fit === 'function') window.term.fit(); };
      window.asterTerminalResize = new ResizeObserver(fit);
      window.asterTerminalResize.observe(document.documentElement);
      window.visualViewport?.addEventListener('resize', fit);
    }
    return true;
    """#
    static let observeSocket = #"""
    if (location.pathname.includes('/webterminal/ttyd/')) {
      const OriginalSocket = window.WebSocket;
      window.WebSocket = class extends OriginalSocket {
        constructor(...args) {
          super(...args);
          const url = new URL(args[0], location.href);
          if (url.host === location.host && url.pathname.startsWith(location.pathname)) {
            window.asterTerminalSocket = this;
            window.asterAttachSent = false; window.asterPersistence = 'waiting';
            let markerText = '';
            this.addEventListener('message', event => {
              // Parse only our fixed session markers, never export shell output.
              if (!window.asterSessionName) return;
              const inspect = text => {
                markerText = (markerText + text).slice(-2048);
                text = markerText;
                if (new RegExp('(?:^|[\\r\\n])ASTEROS_PERSIST_' + window.asterSessionName + '(?:[\\r\\n]|$)').test(text)) window.asterPersistence = 'persistent';
                if (new RegExp('(?:^|[\\r\\n])ASTEROS_NO_TMUX_' + window.asterSessionName + '(?:[\\r\\n]|$)').test(text)) window.asterPersistence = 'unavailable';
              };
              if (event.data instanceof ArrayBuffer) inspect(new TextDecoder().decode(event.data));
              else if (typeof event.data === 'string') inspect(event.data);
            });
          }
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
    private let persistentID = UUID()
    @Published private(set) var persistence = "waiting"
    private var resuming = false
    private var commanderNonce: String?
    @Published private(set) var ready = false
    @Published private(set) var signingIn = false
    @Published private(set) var terminalVisible = false
    @Published private(set) var loading = true
    @Published private(set) var commanderState = "idle"
    @Published var error: String?
    @Published private(set) var fontSize = min(24, max(12, UserDefaults.standard.integer(forKey: "terminalFontSize") == 0 ? 15 : UserDefaults.standard.integer(forKey: "terminalFontSize")))
    func resizeText(_ delta: Int) {
        fontSize = min(24, max(12, fontSize + delta))
        UserDefaults.standard.set(fontSize, forKey: "terminalFontSize")
        Task { await styleTerminal() }
    }
    private func styleTerminal() async {
        guard onTerminal else { return }
        _ = try? await webView.callAsyncJavaScript(TerminalBridge.appearance, arguments: ["fontSize": fontSize], in: nil, contentWorld: .page)
    }
    func showKeyboard() {
        guard onTerminal else { return }
        webView.becomeFirstResponder()
        webView.evaluateJavaScript("window.term?.focus()", completionHandler: nil)
    }
    func hideKeyboard() { webView.endEditing(true) }
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
        webView.isOpaque = false; webView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 23/255, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        observer = TailnetStore.shared.$revision.dropFirst().sink { [weak self] _ in self?.webView.configuration.websiteDataStore.proxyConfigurations = TailnetStore.shared.proxies }
    }
    var onTerminal: Bool { webView.url.map { TerminalPolicy.allows($0, server: server.address) && $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == TerminalPolicy.terminal(server.address).path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? false }
    func pauseObservation() { poll?.cancel(); poll = nil }
    func resume() async {
        guard !resuming else { return }
        resuming = true; defer { resuming = false }
        if webView.url == nil { connect(); return }
        startObservation()
        do {
            webView.configuration.websiteDataStore.proxyConfigurations = try await TailnetStore.shared.prepare(for: server.address.host)
            if onTerminal {
                let state = (try? await webView.evaluateJavaScript("window.asterTerminalSocket?.readyState ?? -1")) as? Int
                // Reopen only the transport. Never resend a user command or start another agent.
                if state != 1 && state != 0 { webView.reload(); ready = false }
                await readStatus()
            }
        } catch { self.error = "Waiting to reconnect the terminal. Your persistent server session can be reattached when the connection returns." }
    }
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
        startObservation()
    }
    private func startObservation() {
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
            await styleTerminal()
            let raw = try await webView.callAsyncJavaScript(TerminalBridge.status, arguments: [:], in: nil, contentWorld: .page) as? String
            guard onTerminal, let data = raw?.data(using: .utf8), let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let transportReady = state["ready"] as? Bool == true
            if let nonce = commanderNonce, agentMayBeRunning {
                _ = try await webView.callAsyncJavaScript("if (!window.asterCommander) window.asterCommander = {nonce,state:'unknown'};", arguments: ["nonce": nonce], in: nil, contentWorld: .page)
            }
            if transportReady {
                let result = try await webView.callAsyncJavaScript(TerminalBridge.attach, arguments: ["sessionName": "asteros-" + persistentID.uuidString.lowercased(), "command": TerminalPolicy.attachCommand(sessionID: persistentID)], in: nil, contentWorld: .page) as? String
                persistence = result ?? "waiting"
            }
            ready = transportReady && (persistence == "persistent" || persistence == "unavailable")
            if ready { loading = false }
            if let value = state["state"] as? String, !(value == "idle" && agentMayBeRunning), !(commanderState == "stopping" && ["requested", "starting", "running"].contains(value)) { commanderState = value }
        } catch { ready = false; if agentMayBeRunning { commanderState = "unknown" } }
    }
    func startCommander() async {
        guard ready, onTerminal, !agentMayBeRunning else { return }
        let nonce = UUID().uuidString
        guard let command = TerminalPolicy.commanderCommand(nonce: nonce) else { return }
        do {
            let sent = try await webView.callAsyncJavaScript(TerminalBridge.start, arguments: ["nonce": nonce, "command": command], in: nil, contentWorld: .page) as? Bool
            if sent == true { commanderNonce = nonce; commanderState = "requested"; error = nil }
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
        // WebKit/terminal helpers can create empty frames. These contain no remote content.
        if action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if let url = action.request.url, action.navigationType == .linkActivated, url.scheme == "https", url.user == nil, url.password == nil, !TerminalPolicy.allows(url, server: server.address) {
            UIApplication.shared.open(url); decisionHandler(.cancel); return
        }
        guard let url = action.request.url, TerminalPolicy.allows(url, server: server.address) else { if action.targetFrame?.isMainFrame != false { error = "This link cannot open inside the server terminal." }; decisionHandler(.cancel); return }
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
@MainActor enum TerminalSessions {
    private static var models: [UUID: ServerTerminalModel] = [:]
    static func model(for server: ServerProfile) -> ServerTerminalModel {
        if let model = models[server.id], model.server.address == server.address { return model }
        models[server.id]?.close()
        let model = ServerTerminalModel(server: server); models[server.id] = model; return model
    }
    static func forget(_ id: UUID) { models.removeValue(forKey: id)?.close() }
}
struct ServerTerminalSurface: UIViewRepresentable {
    let model: ServerTerminalModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
struct ServerTerminalView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCommander = false
    private var commander: Bool { showCommander || model.agentMayBeRunning }
    @StateObject private var model: ServerTerminalModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStart = false
    @State private var confirmClose = false
    @State private var showHelp = false
    init(server: ServerProfile) {
        _model = StateObject(wrappedValue: TerminalSessions.model(for: server))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(model.ready ? Color.mint : Color.secondary).frame(width: 6, height: 6)
                Text(commander ? model.statusText : (model.ready ? model.server.name + (model.persistence == "persistent" ? " · Session retained" : "") : "Connecting…")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if commander {
                    if model.agentMayBeRunning { Button("Stop", role: .destructive) { Task { await model.interrupt() } }.disabled(!model.ready) }
                    else { Button("Start") { confirmStart = true }.disabled(!model.ready) }
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if !model.agentMayBeRunning { Button("Retry") { model.connect() }.font(.caption) }
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            if model.persistence == "unavailable" { Text("Install tmux on Unraid to keep running commands alive if iOS drops the connection. This terminal is retained while available.").font(.caption).foregroundStyle(.orange).padding(.horizontal, 20) }
            if model.signingIn { Text("Sign in to your server to open its terminal.").font(.caption).padding(12) }
            ZStack {
                ServerTerminalSurface(model: model).opacity(model.terminalVisible || model.signingIn ? 1 : 0)
                if model.loading { ProgressView("Opening terminal…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 16/255, green: 18/255, blue: 23/255))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Ctrl+C") { Task { await model.interrupt() } }
                    Button("Tab") { Task { await model.sendKey("\t") } }
                    Button("Esc") { Task { await model.sendKey("\u{1b}") } }
                    Button { Task { await model.sendKey("\u{1b}[A") } } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Previous command")
                    Button { Task { await model.sendKey("\u{1b}[B") } } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Next command")
                    Button { Task { await model.sendKey("\r") } } label: { Image(systemName: "return") }.accessibilityLabel("Return")
                    Button { model.hideKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }.accessibilityLabel("Hide keyboard")
                }.font(.system(.subheadline, design: .monospaced)).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).disabled(!model.ready).padding(10)
            }.asterGlass(radius: 26).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle("Terminal").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(Color(red: 16/255, green: 18/255, blue: 23/255), for: .navigationBar)
        .navigationBarBackButtonHidden(model.agentMayBeRunning)
        .toolbar {
            if model.agentMayBeRunning { ToolbarItem(placement: .cancellationAction) { Button("Close") { confirmClose = true } } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Desktop Commander", systemImage: "desktopcomputer", isOn: $showCommander)
                    Button("Reconnect terminal", systemImage: "arrow.clockwise") { Task { await model.resume() } }
                    Divider()
                    Button("Larger text", systemImage: "textformat.size.larger") { model.resizeText(1) }.disabled(model.fontSize >= 24)
                    Button("Smaller text", systemImage: "textformat.size.smaller") { model.resizeText(-1) }.disabled(model.fontSize <= 12)
                    Button("Keyboard", systemImage: "keyboard") { model.showKeyboard() }
                    Button("Help", systemImage: "questionmark.circle") { showHelp = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Terminal options")
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                GlassForm { Section {
                    Text("Tap the terminal to type. The control strip provides terminal keys; change text size from the options menu.")
                    if commander { Text("Start reuses the installed Desktop Commander. On first use it installs once in appdata. Follow its pairing link if requested. Stop interrupts only the agent started in this session. Wait for Agent exited before closing to confirm it stopped.") }
                    Text("AsterOS keeps this terminal when you leave the screen. With tmux installed, it reconnects to the same server session after a network interruption. Commands continue on Unraid until they finish or you stop them; server reboots end the session.").foregroundStyle(.secondary)
                } }.navigationTitle("Terminal help").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { showHelp = false } }
            }.presentationDetents([.medium, .large])
        }
        .confirmationDialog("Start Desktop Commander on this server?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start Desktop Commander") { Task { await model.startCommander() } }
        } message: { Text("Reconnect using the installed Desktop Commander. If no copy is available, AsterOS installs version 0.2.51 once in appdata. Your paired AI clients get the terminal user’s permissions. Node.js is required; npm is needed only for installation.") }
        .confirmationDialog("Close this terminal?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Stop first") { Task { await model.interrupt() } }
            Button("Leave terminal running") { dismiss() }
        } message: { Text("Leaving this screen retains the terminal. With tmux available, running commands continue on the server during a dropped connection. Use Stop if you want to stop the agent before leaving.") }
        .task { await model.resume() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.resume() } }
            else if phase == .background { model.pauseObservation() }
        }
        .onDisappear { model.pauseObservation() }
    }
}

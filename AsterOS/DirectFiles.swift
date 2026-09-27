import SwiftUI
import UniformTypeIdentifiers
import SMBClient

struct ShareConnection: Codable {
    var id = UUID()
    let host: String
    let username: String
}

@MainActor enum ShareSettings {
    static func addressKey(_ address: URL) -> String { "directShareAddress-" + AppFoldersStore.addressKey(address) }
    static func load(serverID: UUID, address: URL?, defaults: UserDefaults = .standard) -> ShareConnection? {
        let legacy = "directShares-" + serverID.uuidString
        let canonical = address.map(addressKey)
        guard let data = canonical.flatMap({ defaults.data(forKey: $0) }) ?? defaults.data(forKey: legacy),
              let connection = try? JSONDecoder().decode(ShareConnection.self, from: data) else { return nil }
        defaults.set(data, forKey: legacy)
        if let canonical { defaults.set(data, forKey: canonical) }
        return connection
    }
    static func save(_ connection: ShareConnection, serverID: UUID, address: URL?, defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(connection)
        if let previous = load(serverID: serverID, address: address, defaults: defaults) {
            for key in keys(for: previous.id, defaults: defaults) { defaults.set(data, forKey: key) }
        }
        defaults.set(data, forKey: "directShares-" + serverID.uuidString)
        if let address { defaults.set(data, forKey: addressKey(address)) }
    }
    static func keys(for connectionID: UUID, defaults: UserDefaults = .standard) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { key in
            guard key.hasPrefix("directShares-") || key.hasPrefix("directShareAddress-"),
                  let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(ShareConnection.self, from: data) else { return false }
            return saved.id == connectionID
        }
    }
}

enum SharePolicy {
    static func host(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.hasPrefix("smb://") ? value : "smb://" + value
        guard let url = URLComponents(string: address), url.scheme == "smb",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              !host.contains(where: { $0.isWhitespace }), !value.contains("%") else {
            throw AppError.message("Enter a server hostname or IP address, without a port, share path or password.")
        }
        return host
    }
    static func name(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains(where: { "/\\:*?\"<>|".contains($0) || $0.asciiValue.map { $0 < 32 } == true }),
              !name.hasSuffix("."), !name.hasSuffix(" ") else {
            throw AppError.message("Choose a file or folder name without slashes or reserved characters.")
        }
        return name
    }
    static func child(_ name: String, in path: String) throws -> String {
        let safe = try self.name(name)
        return path.isEmpty ? safe : path + "/" + safe
    }
}

struct DirectFile: Identifiable {
    let name: String
    let directory: Bool
    let size: UInt64
    var id: String { name }
}

@MainActor final class DirectFilesStore: ObservableObject {
    @Published private(set) var connection: ShareConnection?
    @Published private(set) var entries: [DirectFile] = []
    @Published private(set) var share: String?
    @Published private(set) var path = ""
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var downloaded: DownloadedFile?
    @Published var progress: Double?
    private let serverID: UUID
    private let serverAddress: URL?
    private var activeClient: SMBClient?
    private var watchdog: Task<Void, Never>?
    private var cancelled = false
    private var timedOut = false
    private var defaultsKey: String { "directShares-" + serverID.uuidString }

    init(serverID: UUID, address: URL? = nil) {
        self.serverID = serverID; self.serverAddress = address
        connection = ShareSettings.load(serverID: serverID, address: address)
    }
    static func forget(serverID: UUID, address: URL? = nil) throws {
        if let connection = ShareSettings.load(serverID: serverID, address: address) {
            try CredentialStore.remove(connection.id)
            for key in ShareSettings.keys(for: connection.id) { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    private func touchTimeout() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.busy else { return }
            self.timedOut = true
            self.activeClient?.session.disconnect()
        }
    }
    private func begin(_ connection: ShareConnection) -> SMBClient {
        busy = true; cancelled = false; timedOut = false; error = nil
        let client = SMBClient(host: connection.host, port: 445, parameters: TailnetStore.shared.smbParameters())
        activeClient = client; touchTimeout()
        return client
    }
    private func finish(_ client: SMBClient) {
        watchdog?.cancel(); watchdog = nil
        client.session.disconnect(); activeClient = nil
        busy = false; progress = nil
    }
    private func check() throws {
        if timedOut { throw AppError.message("The file connection timed out. Check your local network or AsterOS private connection, then retry.") }
        if cancelled || Task.isCancelled { throw CancellationError() }
    }
    private func report(_ error: Error) {
        if timedOut { self.error = "The file connection timed out. Check your local network or AsterOS private connection, then retry." }
        else if cancelled || error is CancellationError { self.error = "Transfer or connection cancelled." }
        else { self.error = "\(error.localizedDescription) Check the share account, its permissions, and your local network or AsterOS private connection." }
    }
    func cancel() { cancelled = true; activeClient?.session.disconnect() }
    private func login(_ client: SMBClient, connection: ShareConnection) async throws {
        let password = try CredentialStore.read(connection.id)
        try await client.login(username: connection.username, password: password, requireSigning: true)
        try check(); touchTimeout()
    }
    private func listing(_ client: SMBClient, share: String?, path: String) async throws -> [DirectFile] {
        if let share {
            try await client.connectShare(share)
            let files = try await client.listDirectory(path: path)
            return files.filter { (try? SharePolicy.name($0.name)) != nil && !$0.name.hasPrefix(".asteros-upload-") && $0.name.range(of: #"^\.asteros-[0-9a-f]{64}\.json$"#, options: .regularExpression) == nil }
                .map { DirectFile(name: $0.name, directory: $0.isDirectory, size: $0.size) }
                .sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let shares = try await client.listShares()
        return shares.filter { $0.type == .diskTree && (try? SharePolicy.name($0.name)) != nil }
            .map { DirectFile(name: $0.name, directory: true, size: 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func connect(host: String, username: String, password: String) async throws {
        guard !busy else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username.lowercased() != "root", !password.isEmpty else {
            throw AppError.message("Use an Unraid share username and password. The root account cannot access SMB shares.")
        }
        let candidate = ShareConnection(host: try SharePolicy.host(host), username: username)
        let client = begin(candidate); defer { finish(client) }
        do {
            try await client.login(username: username, password: password, requireSigning: true)
            try check(); touchTimeout()
            let result = try await listing(client, share: nil, path: "")
            try check()
            try CredentialStore.save(password, for: candidate.id)
            if let old = connection {
                do { try CredentialStore.remove(old.id) }
                catch { try? CredentialStore.remove(candidate.id); throw error }
            }
            try ShareSettings.save(candidate, serverID: serverID, address: serverAddress)
            connection = candidate; share = nil; path = ""; entries = result
        } catch { report(error); throw AppError.message(self.error ?? "Unable to connect.") }
    }
    func browse(share: String?, path: String = "") async {
        guard let connection, !busy else { return }
        let client = begin(connection); defer { finish(client) }
        do {
            try await login(client, connection: connection)
            let result = try await listing(client, share: share, path: path)
            try check()
            self.share = share; self.path = path; entries = result
        } catch { report(error) }
    }
    func refresh() async { await browse(share: share, path: path) }
    func open(_ entry: DirectFile) async {
        if entry.directory {
            if share == nil { await browse(share: entry.name) }
            else if let next = try? SharePolicy.child(entry.name, in: path) { await browse(share: share, path: next) }
        } else { await download(entry) }
    }
    func up() async {
        if path.isEmpty { await browse(share: nil) }
        else { await browse(share: share, path: path.split(separator: "/").dropLast().joined(separator: "/")) }
    }
    func createFolder(_ name: String) async {
        guard let connection, let share, !busy else { return }
        let client = begin(connection)
        do {
            let target = try SharePolicy.child(name, in: path)
            try await login(client, connection: connection)
            try await client.connectShare(share)
            try check()
            try await client.createDirectory(path: target)
            try check(); finish(client); await refresh()
        } catch { report(error); finish(client) }
    }
    func upload(_ url: URL) async {
        guard let connection, let share, !busy else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let client = begin(connection); progress = 0
        do {
            let target = try SharePolicy.child(url.lastPathComponent, in: path)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw AppError.message("Select a regular file to upload.")
            }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            try await login(client, connection: connection)
            try await client.connectShare(share)
            try check()
            // Write only our unique staging file. Rename refuses an existing destination.
            let staging = try SharePolicy.child(".asteros-upload-" + UUID().uuidString, in: path)
            let writer = client.fileWriter(path: staging)
            do {
                try await writer.upload(fileHandle: file) { value in
                    Task { @MainActor [weak self] in self?.progress = value; self?.touchTimeout() }
                }
                try await writer.close()
                try check()
                try await client.move(from: staging, to: target)
                try check()
            } catch {
                try? await writer.close()
                // Never delete the destination, including when rename reports a collision.
                if !cancelled && !timedOut { try? await client.deleteFile(path: staging) }
                throw error
            }
            finish(client); await refresh()
        } catch { report(error); finish(client) }
    }
    func download(_ entry: DirectFile) async {
        guard let connection, let share, !busy else { return }
        let client = begin(connection); progress = 0
        defer { finish(client) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AsterOS-" + UUID().uuidString)
        do {
            let remote = try SharePolicy.child(entry.name, in: path)
            let destination = directory.appendingPathComponent(try SharePolicy.name(entry.name))
            try await login(client, connection: connection)
            try await client.connectShare(share)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reader = client.fileReader(path: remote)
            do {
                try await reader.download(to: destination, overwrite: false) { value in
                    Task { @MainActor [weak self] in self?.progress = value; self?.touchTimeout() }
                }
                try await reader.close(); try check()
            } catch { try? await reader.close(); throw error }
            downloaded = DownloadedFile(url: destination)
        } catch { try? FileManager.default.removeItem(at: directory); report(error) }
    }
    func clearDownload() {
        if let file = downloaded { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        downloaded = nil
    }
    func forget() {
        guard !busy else { return }
        do {
            try Self.forget(serverID: serverID, address: serverAddress)
            connection = nil; share = nil; path = ""; entries = []; error = nil
        } catch { report(error) }
    }
}

struct FilesView: View {
    @EnvironmentObject var app: AppStore
    var body: some View {
        if let server = app.selected, !app.demo {
            DirectFilesView(server: server).id("files-" + server.id.uuidString)
        } else {
            NavigationStack {
                ContentUnavailableView("Connect a server", systemImage: "folder", description: Text("Add your Unraid server to browse its shares directly. No companion download is required."))
                    .background { AsterBackdrop() }
            .navigationTitle("Files")
            }
        }
    }
}

struct DirectFilesView: View {
    let server: ServerProfile
    @StateObject private var store: DirectFilesStore
    @State private var setup = false
    @State private var companion = false
    @State private var importing = false
    @State private var creating = false
    @State private var folder = ""
    @State private var search = ""
    @State private var shareFile: DownloadedFile?
    init(server: ServerProfile) {
        self.server = server
        _store = StateObject(wrappedValue: DirectFilesStore(serverID: server.id, address: server.address))
    }
    var body: some View {
        NavigationStack {
            Group {
                if store.connection == nil {
                    ContentUnavailableView {
                        Label("Your Unraid files", systemImage: "folder.fill")
                    } description: {
                        Text("Browse shares, upload and download directly. Connect with an Unraid share account on your local network or AsterOS private connection.")
                    } actions: {
                        Button("Connect shares") { setup = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Label(store.connection?.host ?? server.name, systemImage: "server.rack").font(.caption).foregroundStyle(.secondary)
                            if let share = store.share {
                                Button { Task { await store.up() } } label: {
                                    Label(store.path.isEmpty ? "All shares" : "Parent folder", systemImage: "chevron.left")
                                }.disabled(store.busy)
                                Text(store.path.isEmpty ? share : share + "/" + store.path).font(.headline).textSelection(.enabled)
                            } else { Text("Shares").font(.title2.bold()) }
                            if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                            if store.busy {
                                HStack {
                                    if let value = store.progress { ProgressView("Transferring…", value: value) }
                                    else { ProgressView("Connecting…") }
                                    Spacer(); Button("Cancel") { store.cancel() }
                                }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 20)], spacing: 28) {
                                ForEach(store.entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { entry in
                                    Button { Task { await store.open(entry) } } label: {
                                        VStack(spacing: 10) {
                                            Image(systemName: entry.directory ? "folder.fill" : "doc.fill")
                                                .font(.system(size: 58, weight: .light)).foregroundStyle(entry.directory ? Color.orange.gradient : Color.mint.gradient).shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                                                .frame(height: 76)
                                            Text(entry.name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                            if !entry.directory {
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }.frame(maxWidth: .infinity, minHeight: 125, alignment: .top)
                                    }.buttonStyle(.plain).disabled(store.busy)
                                }
                            }
                            if store.entries.isEmpty && !store.busy && store.error == nil { Text("No items in this location.").foregroundStyle(.secondary) }
                            Text("Transfers run while AsterOS is open. Share permissions control what you can read and write.").font(.caption).foregroundStyle(.secondary)
                        }.padding(20)
                    }.refreshable { await store.refresh() }.searchable(text: $search, prompt: "Search this folder")
                }
            }
            .background { AsterBackdrop() }
            .navigationTitle("Files")
            .toolbar {
                Menu {
                    if store.share != nil {
                        Button("Upload file", systemImage: "arrow.up.doc") { importing = true }
                        Button("New folder", systemImage: "folder.badge.plus") { creating = true }
                    }
                    if store.connection != nil {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        Button("Forget share connection", systemImage: "person.crop.circle.badge.minus") { store.forget() }
                    }
                    Button("Share connection", systemImage: "network") { setup = true }
                    Button("Companion connection (optional)", systemImage: "shippingbox") { companion = true }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(store.busy)
            }
            .task { await store.refresh() }
            .onDisappear { store.cancel() }
            .sheet(isPresented: $setup) { ShareConnectionView(store: store, suggestedHost: server.address.host ?? "") }
            .sheet(isPresented: $companion) { CompanionFilesView() }
            .onChange(of: store.downloaded?.id) { _, _ in shareFile = store.downloaded }
            .sheet(item: $shareFile, onDismiss: { store.clearDownload() }) { ShareFile(url: $0.url) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): Task { await store.upload(url) }
                case .failure(let error): store.error = error.localizedDescription
                }
            }
            .alert("New folder", isPresented: $creating) {
                TextField("Folder name", text: $folder)
                Button("Create") { let name = folder; folder = ""; Task { await store.createFolder(name) } }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

struct ShareConnectionView: View {
    @ObservedObject var store: DirectFilesStore
    let suggestedHost: String
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            GlassForm {
                Section("Server") {
                    TextField("Hostname or IP address", text: $host).keyboardType(.URL)
                    Text("Use the server’s full Tailscale name or IP for the AsterOS private connection, or its LAN address on Wi-Fi.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Unraid share account") {
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    Text("Use an account from Unraid → Users with access to your shares. This is separate from your Unraid web login; root cannot access shares. The password stays in this device’s Keychain.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button(store.busy ? "Connecting…" : "Connect shares") {
                    Task {
                        do { try await store.connect(host: host, username: username, password: password); password = ""; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(store.busy || host.isEmpty || username.isEmpty || password.isEmpty)
                Section { Text("Use a trusted local network or VPN. Do not forward SMB port 445 to the internet. No additional server app is required.").font(.caption).foregroundStyle(.secondary) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Connect shares")
            .toolbar { Button("Cancel") { store.cancel(); password = ""; dismiss() } }
            .interactiveDismissDisabled(store.busy)
            .onAppear { host = store.connection?.host ?? suggestedHost; username = store.connection?.username ?? "" }
        }
    }
}

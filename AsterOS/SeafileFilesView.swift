import SwiftUI
import UniformTypeIdentifiers

@MainActor final class SeafileFilesStore: ObservableObject {
    let server: URL
    @Published var connection: SeafileConnection?
    @Published var libraries: [SeafileLibrary] = []
    @Published var selected: SeafileLibrary?
    @Published var entries: [SeafileEntry] = []
    @Published var path = ""
    @Published var busy = false
    @Published var progress: Double?
    @Published var error: String?
    @Published var downloaded: DownloadedFile?
    private var api: SeafileClient?
    init(server: URL) { self.server = server; connection = SeafileSettings.load(server) }
    func run(_ action: (SeafileClient) async throws -> Void) async {
        guard !busy else { return }
        guard let connection else { return }
        busy = true; error = nil; progress = nil
        defer { busy = false; progress = nil; api?.disconnect(); api = nil }
        do {
            let client = SeafileClient(connection: connection, token: try CredentialStore.read(connection.id)); api = client
            try await action(client)
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        await run { client in
            if let selected { try await client.select(selected.id); entries = try await client.list(path) }
            else { libraries = try await client.libraries() }
        }
    }
    func openLibrary(_ item: SeafileLibrary) async {
        guard !busy else { return }; selected = item; path = ""; entries = []; await refresh()
    }
    func up() async {
        guard !busy else { return }
        if path.isEmpty { selected = nil } else { path = path.split(separator: "/").dropLast().joined(separator: "/") }
        entries = []; await refresh()
    }
    func open(_ entry: SeafileEntry) async {
        if entry.isDirectory {
            guard !busy else { return }
            do { path = try SharePolicy.child(entry.name, in: path); entries = []; await refresh() } catch { self.error = error.localizedDescription }
        } else {
            await run { client in
                guard let selected else { return }; try await client.select(selected.id)
                let file = try await client.download(SharePolicy.child(entry.name, in: path))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("asteros-seafile-preview-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let named = directory.appendingPathComponent(try SharePolicy.name(entry.name))
                try FileManager.default.moveItem(at: file, to: named)
                downloaded = DownloadedFile(url: named)
            }
        }
    }
    func mkdir(_ name: String) async {
        await run { client in
            guard let selected else { return }; try await client.select(selected.id, writing: true)
            try await client.mkdir(SharePolicy.child(name, in: path)); entries = try await client.list(path)
        }
    }
    func upload(_ file: URL) async {
        let accessing = file.startAccessingSecurityScopedResource(); defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        await run { client in
            guard let selected else { return }; try await client.select(selected.id, writing: true)
            let destination = try SharePolicy.child(file.lastPathComponent, in: path)
            guard try await !client.list(path).contains(where: { $0.name == file.lastPathComponent }) else { throw AppError.message("A file with that name already exists. Rename your file before uploading.") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            try await client.upload(handle, path: destination) { [weak self] value in Task { @MainActor in self?.progress = value } }
            entries = try await client.list(path)
        }
    }
    func clearDownload() {
        if let downloaded { try? FileManager.default.removeItem(at: downloaded.url.deletingLastPathComponent()) }
        downloaded = nil
    }
}
struct SeafileFilesView: View {
    let server: ServerProfile
    @StateObject private var store: SeafileFilesStore
    @State private var setup = false
    @State private var importing = false
    @State private var creating = false
    @State private var folder = ""
    init(server: ServerProfile) { self.server = server; _store = StateObject(wrappedValue: SeafileFilesStore(server: server.address)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.connection == nil {
                        ContentUnavailableView("Your Seafile libraries", systemImage: "externaldrive.badge.icloud", description: Text("Connect Seafile to browse files and choose a photo backup destination."))
                        Button("Connect Seafile") { setup = true }.buttonStyle(.borderedProminent)
                    } else {
                        Text(store.connection!.address.host ?? "Seafile").font(.caption).foregroundStyle(.secondary)
                        if store.selected != nil { Button("Parent folder", systemImage: "chevron.left") { Task { await store.up() } }.disabled(store.busy) }
                        Text(store.selected.map { $0.name + (store.path.isEmpty ? "" : "/" + store.path) } ?? "Libraries").font(.title2.bold())
                        if store.busy { if let progress = store.progress { ProgressView("Uploading…", value: progress) } else { ProgressView("Connecting…") } }
                        if store.selected == nil {
                            ForEach(store.libraries) { item in
                                Button { Task { await store.openLibrary(item) } } label: {
                                    Label(item.name + (item.encrypted ? " · encrypted" : item.writable ? "" : " · read only"), systemImage: item.encrypted ? "lock" : "books.vertical").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                                }.disabled(store.busy || item.encrypted)
                            }
                        } else {
                            ForEach(store.entries.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }) { entry in
                                Button { Task { await store.open(entry) } } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").font(.title).foregroundStyle(.mint)
                                        Text(entry.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        Spacer()
                                        if let size = entry.size, !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical, 10)
                                }.disabled(store.busy)
                            }
                        }
                    }
                    if let error = store.error { Text(error).foregroundStyle(.orange) }
                }.padding(20)
            }.background { AsterBackdrop() }.navigationTitle("Files")
            .refreshable { await store.refresh() }
            .toolbar {
                Menu {
                    Button("Seafile connection") { setup = true }
                    Button("Refresh") { Task { await store.refresh() } }
                    if store.selected?.writable == true {
                        Button("Upload file") { importing = true }
                        Button("New folder") { creating = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(store.busy)
            }
            .task { await store.refresh() }
            .sheet(isPresented: $setup, onDismiss: { store.connection = SeafileSettings.load(server.address); store.selected = nil; store.path = ""; Task { await store.refresh() } }) { SeafileConnectionView(server: server.address) }
            .sheet(item: $store.downloaded, onDismiss: { store.clearDownload() }) { ShareFile(url: $0.url) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                switch result { case .success(let url): Task { await store.upload(url) }; case .failure(let error): store.error = error.localizedDescription }
            }
            .alert("New folder", isPresented: $creating) {
                TextField("Folder name", text: $folder)
                Button("Create") { let name = folder; folder = ""; Task { await store.mkdir(name) } }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}
struct SeafileConnectionView: View {
    let server: URL
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var useToken = false
    @State private var localHTTP = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            GlassForm {
                Section("Seafile server") {
                    TextField("https://cloud.example.com", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if let url = URL(string: address), LocalHTTPPolicy.eligible(url) {
                        Toggle("Allow HTTP on my local network", isOn: $localHTTP)
                        Text("HTTP sends your token and file contents without encryption. Use only on your trusted home network. Cellular transfers are blocked for this connection.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Use an existing API token", isOn: $useToken)
                    if useToken {
                        SecureField("Account API token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("Seafile email", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                        SecureField("Password", text: $password)
                        TextField("Two-factor code (if enabled)", text: $otp).keyboardType(.numberPad)
                    }
                    Text("Sign in to Seafile or use an account API token (not a library token or Unraid key). Only the token is saved in iPhone Keychain. Your password is not stored.").font(.caption).foregroundStyle(.secondary)
                    Text("Encrypted libraries are not supported in this version. Existing libraries and files are never imported into Seafile’s internal data folders.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button("Connect Seafile") { Task { await connect() } }.disabled(busy || (useToken ? token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : email.isEmpty || password.isEmpty))
                if busy { ProgressView("Checking Seafile…") }
            }.navigationTitle("Connect Seafile")
            .toolbar { Button("Cancel") { dismiss() }.disabled(busy) }
            .onAppear { if let saved = SeafileSettings.load(server) { address = saved.address.absoluteString; localHTTP = LocalHTTPPolicy.approved(saved.address) } }
            .onChange(of: address) { _, value in localHTTP = URL(string: value).map { LocalHTTPPolicy.approved($0) } ?? false }
        }
    }
    private func connect() async {
        busy = true; error = nil; defer { busy = false }
        do {
            if let url = URL(string: address), LocalHTTPPolicy.eligible(url) { LocalHTTPPolicy.setApproved(localHTTP, for: url) }
            let url = try SeafilePolicy.address(address)
            let previous = SeafileSettings.load(server)
            var connection = SeafileConnection(address: url)
            if let previous, previous.address == url { connection.id = previous.id }
            let value: String
            if useToken { value = token.trimmingCharacters(in: .whitespacesAndNewlines) }
            else {
                let auth = SeafileClient(connection: connection, token: ""); defer { auth.disconnect() }
                value = try await auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, otp: otp)
            }
            let client = SeafileClient(connection: connection, token: value); defer { client.disconnect() }
            _ = try await client.libraries()
            try SeafileSettings.save(connection, token: value, server: server)
            token = ""; password = ""; otp = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

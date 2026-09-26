import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct CompanionProfile: Codable {
    var id = UUID()
    var address: URL
}
struct PairReply: Decodable { let token: String; let device_id: String }
struct FileEntry: Decodable, Identifiable {
    let name: String; let path: String; let directory: Bool; let size: Int64
    var id: String { path }
}
struct FileListing: Decodable { let path: String; let entries: [FileEntry] }
struct UploadReply: Decodable { let id: String; let path: String; let size: Int64; let offset: Int64; let status: String }
struct CompanionOK: Decodable { }
struct PendingUpload: Codable { let id: String; let digest: String; let path: String; let size: Int64 }
struct DownloadedFile: Identifiable { let id = UUID(); let url: URL }

@MainActor final class CompanionStore: ObservableObject {
    @Published private(set) var profile: CompanionProfile?
    @Published var entries: [FileEntry] = []
    @Published var path = ""
    @Published var error: String?
    @Published var busy = false
    @Published var progress: Double?
    @Published var downloaded: DownloadedFile?
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        if let data = UserDefaults.standard.data(forKey: "companionProfile") { profile = try? JSONDecoder().decode(CompanionProfile.self, from: data) }
    }
    private func request(profile: CompanionProfile, route: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [], authorized: Bool = true, binary: Bool = false) throws -> URLRequest {
        var components = URLComponents(url: profile.address.appendingPathComponent(route), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AppError.message("Invalid companion address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        if method == "POST" && body == nil { request.httpBody = Data(); request.setValue("0", forHTTPHeaderField: "Content-Length") }
        request.setValue(binary ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        if authorized { request.setValue("Bearer \(try CredentialStore.read(profile.id))", forHTTPHeaderField: "Authorization") }
        return request
    }
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data,response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("Invalid companion response.") }
        guard (200...299).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw AppError.message(reason ?? "Companion returned HTTP \(http.statusCode). Check its URL, device pairing and HTTPS proxy.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func pair(address: String, code: String) async throws {
        busy = true; defer { busy = false }
        let candidate = CompanionProfile(address: try AddressPolicy.validate(address))
        let body = try JSONSerialization.data(withJSONObject: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines), "name": UIDevice.current.name])
        let response: PairReply = try await send(request(profile: candidate, route: "v1/pair", method: "POST", body: body, authorized: false))
        try CredentialStore.save(response.token, for: candidate.id)
        if let old = profile { try? CredentialStore.remove(old.id) }
        profile = candidate; path = ""; entries = []; error = nil
        UserDefaults.standard.set(try JSONEncoder().encode(candidate), forKey: "companionProfile")
    }
    func refresh() async {
        guard let profile, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result: FileListing = try await send(request(profile: profile, route: "v1/files", query: [URLQueryItem(name: "path", value: path)]))
            entries = result.entries; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func createFolder(_ name: String) async {
        guard let profile, !busy else { return }
        busy = true
        do {
            let destination = path.isEmpty ? name : "\(path)/\(name)"
            let body = try JSONSerialization.data(withJSONObject: ["path": destination])
            let _: CompanionOK = try await send(request(profile: profile, route: "v1/folders", method: "POST", body: body))
            error = nil
        } catch { self.error = error.localizedDescription; busy = false; return }
        busy = false; await refresh()
    }
    func upload(_ url: URL) async {
        guard let profile, !busy else { return }
        busy = true; progress = 0
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() }; busy = false; progress = nil }
        do {
            let fingerprint = try await Task.detached(priority: .utility) {
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var hash = SHA256(); var size: Int64 = 0
                while let chunk = try file.read(upToCount: 4*1024*1024), !chunk.isEmpty { hash.update(data: chunk); size += Int64(chunk.count) }
                return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
            }.value
            let (size,digest) = fingerprint
            let destination = path.isEmpty ? url.lastPathComponent : "\(path)/\(url.lastPathComponent)"
            let savedKey = "companionUpload-\(profile.id.uuidString)-\(digest)"
            var task: UploadReply
            if let data = UserDefaults.standard.data(forKey: savedKey),
               let saved = try? JSONDecoder().decode(PendingUpload.self, from: data), saved.path == destination, saved.size == size {
                task = try await send(request(profile: profile, route: "v1/uploads/\(saved.id)"))
            } else {
                let body = try JSONSerialization.data(withJSONObject: ["path": destination,"size": size,"sha256": digest])
                task = try await send(request(profile: profile, route: "v1/uploads", method: "POST", body: body))
                UserDefaults.standard.set(try JSONEncoder().encode(PendingUpload(id: task.id, digest: digest, path: destination, size: size)), forKey: savedKey)
            }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            try file.seek(toOffset: UInt64(task.offset))
            while task.offset < size {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: 4*1024*1024), !chunk.isEmpty else { throw AppError.message("The selected file changed during upload.") }
                task = try await send(request(profile: profile, route: "v1/uploads/\(task.id)", method: "PUT", body: chunk, query: [URLQueryItem(name: "offset", value: String(task.offset))], binary: true))
                progress = size > 0 ? Double(task.offset)/Double(size) : 1
            }
            let _: UploadReply = try await send(request(profile: profile, route: "v1/uploads/\(task.id)/complete", method: "POST"))
            UserDefaults.standard.removeObject(forKey: savedKey)
            error = nil
            // Refresh after the transfer without racing another operation.
            let listing: FileListing = try await send(request(profile: profile, route: "v1/files", query: [URLQueryItem(name: "path", value: path)]))
            entries = listing.entries
        } catch { self.error = "\(error.localizedDescription) Select the same file again to resume an interrupted transfer." }
    }
    func download(_ entry: FileEntry) async {
        guard let profile, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let request = try request(profile: profile, route: "v1/file", query: [URLQueryItem(name: "path", value: entry.path)])
            let (temporary,response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.message("Download failed. Check the connection and pairing.") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent((entry.name as NSString).lastPathComponent)
            try FileManager.default.moveItem(at: temporary, to: target)
            downloaded = DownloadedFile(url: target); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func revoke() async {
        guard let profile, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let _: CompanionOK = try await send(request(profile: profile, route: "v1/device", method: "DELETE"))
            try CredentialStore.remove(profile.id)
            UserDefaults.standard.removeObject(forKey: "companionProfile")
            self.profile = nil; entries = []; path = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
struct CompanionFilesView: View {
    @StateObject private var store = CompanionStore()
    @State private var pairing = false
    @State private var importing = false
    @State private var creating = false
    @State private var folderName = ""
    var body: some View {
        NavigationStack {
            Group {
                if let profile = store.profile {
                    List {
                        Section {
                            Label(profile.address.host ?? "Companion", systemImage: "externaldrive.connected.to.line.below")
                            Text(store.path.isEmpty ? "AsterOS storage" : store.path).font(.caption).foregroundStyle(.secondary)
                            if !store.path.isEmpty { Button("Parent folder") { store.path = store.path.split(separator: "/").dropLast().joined(separator: "/"); Task { await store.refresh() } }.disabled(store.busy) }
                            if let progress = store.progress { ProgressView("Uploading", value: progress) }
                            if let error = store.error { Text(error).foregroundStyle(.orange) }
                        }
                        Section("Files") {
                            if store.entries.isEmpty { Text("No files loaded in this folder.").foregroundStyle(.secondary) }
                            ForEach(store.entries) { entry in
                                Button {
                                    if entry.directory { store.path = entry.path; Task { await store.refresh() } }
                                    else { Task { await store.download(entry) } }
                                } label: {
                                    Label { VStack(alignment: .leading) { Text(entry.name); if !entry.directory { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) } } } icon: { Image(systemName: entry.directory ? "folder.fill" : "doc.fill").foregroundStyle(entry.directory ? .yellow : .mint) }
                                }.disabled(store.busy)
                            }
                        }
                        Section { Text("Only the companion’s dedicated storage is visible. Choose a file to download and share. Interrupted uploads resume when you select the same source file again.").font(.caption).foregroundStyle(.secondary) }
                    }.refreshable { await store.refresh() }
                } else {
                    ContentUnavailableView { Label("Connect your files", systemImage: "folder.badge.gearshape") } description: { Text("Pair with AsterOS Companion on your server to browse files and upload them securely.") } actions: { Button("Pair companion") { pairing = true }.buttonStyle(.borderedProminent) }
                }
            }.navigationTitle("Files")
                .toolbar {
                    if store.profile != nil {
                        Menu {
                            Button("Upload file", systemImage: "arrow.up.doc") { importing = true }
                            Button("New folder", systemImage: "folder.badge.plus") { creating = true }
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                            Button("Revoke this connection", role: .destructive) { Task { await store.revoke() } }
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(store.busy)
                    }
                }
                .task { await store.refresh() }
                .sheet(isPresented: $pairing, onDismiss: { Task { await store.refresh() } }) { CompanionPairView(store: store) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                    switch result { case .success(let url): Task { await store.upload(url) }; case .failure(let error): store.error = error.localizedDescription }
                }
                .sheet(item: $store.downloaded) { file in ShareFile(url: file.url) }
                .alert("New folder", isPresented: $creating) {
                    TextField("Folder name", text: $folderName)
                    Button("Create") { let name = folderName; folderName = ""; Task { await store.createFolder(name) } }
                    Button("Cancel", role: .cancel) { }
                }
        }
    }
}
struct CompanionPairView: View {
    @ObservedObject var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("AsterOS Companion") {
                    TextField("https://companion.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("One-time pairing code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Generate a pairing code on your server. It expires after five minutes. The companion address is separate from your Unraid dashboard address.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button(store.busy ? "Pairing…" : "Pair this device") {
                    Task { do { try await store.pair(address: address, code: code); code = ""; dismiss() } catch { self.error = error.localizedDescription } }
                }.disabled(store.busy || address.isEmpty || code.isEmpty)
            }.navigationTitle("Pair companion").toolbar { Button("Cancel") { dismiss() }.disabled(store.busy) }.interactiveDismissDisabled(store.busy)
        }
    }
}
struct ShareFile: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

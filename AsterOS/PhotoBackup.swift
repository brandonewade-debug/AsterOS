import SwiftUI
import Photos
import SMBClient
import CryptoKit

struct PhotoBackupReceipt: Codable {
    struct Resource: Codable { let name: String; let size: UInt64 }
    let version: Int
    let asset: String
    let files: [Resource]
    func matches(_ entries: [String: UInt64], asset expected: String) -> Bool {
        version == 1 && asset == expected && !files.isEmpty && Set(files.map(\.name)).count == files.count && files.allSatisfy { (try? SharePolicy.name($0.name)) != nil && entries[$0.name] == $0.size }
    }
}
enum PhotoBackupPolicy {
    static func identifier(_ localID: String, modified: Date?) -> String {
        SHA256.hash(data: Data("\(localID)|\(modified?.timeIntervalSince1970 ?? 0)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor final class PhotoBackupStore: ObservableObject {
    @Published var share = ""
    @Published var folder = "AsterOS Photos"
    @Published var shares: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var backingUp = false
    @Published private(set) var status = "Choose a backup destination"
    @Published private(set) var count = 0
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var limited = false
    @Published var error: String?
    private let serverID: UUID
    private var client: SMBClient?
    private var watchdog: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var paused = false
    private var timedOut = false
    private var settingsKey: String { "photoBackup-" + serverID.uuidString }
    var hasShareAccount: Bool { UserDefaults.standard.data(forKey: "directShares-" + serverID.uuidString) != nil }
    init(serverID: UUID) {
        self.serverID = serverID
        if let saved = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: String] {
            share = saved["share"] ?? ""; folder = saved["folder"] ?? "AsterOS Photos"
        }
        refreshPhotoCount()
    }
    func refreshPhotoCount() {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        limited = auth == .limited
        count = (auth == .authorized || auth == .limited) ? assets().count : 0
    }
    private func assets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: options)
    }
    func allowPhotos() async {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized || auth == .limited else { error = "Allow Photos access in iPhone Settings → Apps → AsterOS to choose what to back up."; return }
        error = nil; refreshPhotoCount()
    }
    private func check() throws {
        try Task.checkCancellation()
        if paused { throw CancellationError() }
        if timedOut { throw AppError.message("The file connection timed out. Retry after checking your connection.") }
    }
    private func touch() {
        guard busy else { return }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.timedOut = true; self?.client?.session.disconnect()
        }
    }
    private func openShareClient() async throws -> SMBClient {
        guard let data = UserDefaults.standard.data(forKey: "directShares-" + serverID.uuidString) else {
            throw AppError.message("Connect your Unraid share account in Files first, then return here.")
        }
        let connection = try JSONDecoder().decode(ShareConnection.self, from: data)
        _ = try await TailnetStore.shared.prepare(for: connection.host)
        try check()
        let result = SMBClient(host: connection.host, port: 445, parameters: TailnetStore.shared.smbParameters())
        client = result; touch()
        try await result.login(username: connection.username, password: CredentialStore.read(connection.id), requireSigning: true)
        try check(); touch()
        return result
    }
    private func finish() {
        watchdog?.cancel(); watchdog = nil; client?.session.disconnect(); client = nil
        busy = false; backingUp = false; task = nil
    }
    func loadShares() async {
        guard !busy else { return }
        busy = true; error = nil; paused = false; timedOut = false
        defer { finish() }
        do {
            let client = try await openShareClient()
            shares = try await client.listShares().filter { $0.type == .diskTree && (try? SharePolicy.name($0.name)) != nil }.map(\.name).sorted()
            if !shares.contains(share) { share = "" }
            status = "Choose a share and grant Photos access"
        } catch { self.error = error.localizedDescription }
    }
    func start(limit: Int? = nil) {
        guard !busy else { return }
        busy = true; backingUp = true; paused = false; timedOut = false; error = nil; completed = 0; progress = 0
        let destinationShare = share, destinationFolder = folder
        task = Task { await backup(share: destinationShare, folder: destinationFolder, limit: limit) }
    }
    func pause() {
        guard backingUp else { return }
        paused = true; status = "Pausing…"; task?.cancel(); client?.session.disconnect()
    }
    private func backup(share: String, folder: String, limit: Int?) async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("asteros-photos-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary); finish() }
        do {
            _ = try SharePolicy.name(share); _ = try SharePolicy.name(folder)
            let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard auth == .authorized || auth == .limited else { throw AppError.message("Tap Allow Photos before starting backup.") }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let client = try await openShareClient()
            try await client.connectShare(share); try check(); touch()
            let root = try await client.listDirectory(path: "")
            if let existing = root.first(where: { $0.name == folder }) {
                guard existing.isDirectory else { throw AppError.message("The backup folder name is already used by a file.") }
            } else { try await client.createDirectory(path: folder) }
            UserDefaults.standard.set(["share": share, "folder": folder], forKey: settingsKey)
            let folders = try await client.listDirectory(path: folder)
            var knownFolders = Set(folders.filter(\.isDirectory).map(\.name))
            let fetched = assets(); count = fetched.count
            total = min(count, max(0, limit ?? count))
            for index in 0..<total {
                try check(); touch()
                let asset = fetched.object(at: fetched.count - total + index)
                let identity = PhotoBackupPolicy.identifier(asset.localIdentifier, modified: asset.modificationDate)
                let path = try SharePolicy.child(identity, in: folder)
                status = "Checking item \(index + 1) of \(total)"
                if !knownFolders.contains(identity) { try await client.createDirectory(path: path); knownFolders.insert(identity) }
                let existing = try await client.listDirectory(path: path)
                let sizes = Dictionary(existing.filter { !$0.isDirectory }.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
                if let receiptSize = sizes["complete.json"] {
                    guard receiptSize < 1_000_000 else { throw AppError.message("An existing backup receipt is invalid. Choose a new backup folder.") }
                    let reader = client.fileReader(path: path + "/complete.json")
                    let bytes: Data
                    do { bytes = try await reader.read(offset: 0, length: 1_000_000); try await reader.close() }
                    catch { try? await reader.close(); throw error }
                    guard let receipt = try? JSONDecoder().decode(PhotoBackupReceipt.self, from: bytes), receipt.matches(sizes, asset: identity) else {
                        throw AppError.message("A previous backup is missing files or has changed. Choose a new folder to make another complete copy; existing files were left untouched.")
                    }
                    completed += 1; continue
                }
                // Export every available resource: originals, Live Photo video and edit resources.
                let resources = PHAssetResource.assetResources(for: asset)
                guard !resources.isEmpty else { throw AppError.message("Photos did not provide the original resources for an item.") }
                var records: [PhotoBackupReceipt.Resource] = []
                for (resourceIndex, resource) in resources.enumerated() {
                    try check()
                    let name = try SharePolicy.name("\(resourceIndex)-" + resource.originalFilename)
                    let file = temporary.appendingPathComponent(UUID().uuidString)
                    status = "Preparing \(index + 1) of \(total) from Photos…"; progress = 0
                    watchdog?.cancel()
                    let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
                    try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
                    try check(); touch()
                    let size = UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    if let previous = sizes[name] {
                        guard previous == size else { throw AppError.message("An unfinished backup has a conflicting file. Choose a new backup folder.") }
                        // Crash recovery: compare bytes before accepting a file without a completion receipt.
                        let reader = client.fileReader(path: path + "/" + name)
                        let local = try FileHandle(forReadingFrom: file)
                        do {
                            var offset: UInt64 = 0
                            while offset < size {
                                try check(); touch()
                                let remote = try await reader.read(offset: offset, length: 1_048_576)
                                let expected = try local.read(upToCount: remote.count) ?? Data()
                                guard !remote.isEmpty, remote == expected else { throw AppError.message("An unfinished backup differs from the original. Choose a new backup folder.") }
                                offset += UInt64(remote.count)
                            }
                            try local.close(); try await reader.close()
                        } catch { try? local.close(); try? await reader.close(); throw error }
                    } else {
                        status = "Backing up \(index + 1) of \(total)"
                        try await upload(file, to: path + "/" + name, client: client, size: size)
                    }
                    records.append(.init(name: name, size: size))
                    try FileManager.default.removeItem(at: file)
                }
                let receipt = PhotoBackupReceipt(version: 1, asset: identity, files: records)
                let file = temporary.appendingPathComponent("complete.json")
                let encoded = try JSONEncoder().encode(receipt); try encoded.write(to: file, options: .atomic)
                try await upload(file, to: path + "/complete.json", client: client, size: UInt64(encoded.count))
                completed += 1
            }
            progress = 1; status = "Backup complete · \(completed) items"
        } catch {
            if paused || error is CancellationError { status = "Paused · tap Back up now to continue" }
            else { status = "Backup stopped"; self.error = error.localizedDescription }
        }
    }
    private func upload(_ file: URL, to destination: String, client: SMBClient, size: UInt64) async throws {
        let parent = destination.split(separator: "/").dropLast().joined(separator: "/")
        let staging = parent + "/.asteros-upload-" + UUID().uuidString
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let writer = client.fileWriter(path: staging)
        do {
            touch()
            try await writer.upload(fileHandle: handle) { value in Task { @MainActor [weak self] in self?.progress = value; self?.touch() } }
            try await writer.close(); try check(); touch()
            let reader = client.fileReader(path: staging)
            let written: UInt64
            do { written = try await reader.fileSize; try await reader.close() }
            catch { try? await reader.close(); throw error }
            guard written == size else { throw AppError.message("The server did not receive the complete file. Retry backup.") }
            try await client.move(from: staging, to: destination)
            try check(); touch()
        } catch {
            try? await writer.close()
            if !paused && !timedOut { try? await client.deleteFile(path: staging) }
            throw error
        }
    }
}

struct PhotosView: View {
    @EnvironmentObject var app: AppStore
    var body: some View {
        if let server = app.selected, !app.demo { PhotoBackupView(server: server).id(server.id) }
        else { NavigationStack { ContentUnavailableView("Connect your server", systemImage: "photo", description: Text("Connect Unraid to set up photo backup to one of its shares.")).navigationTitle("Photos") } }
    }
}
struct PhotoBackupView: View {
    let server: ServerProfile
    @StateObject private var backup: PhotoBackupStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var confirm = false
    init(server: ServerProfile) { self.server = server; _backup = StateObject(wrappedValue: PhotoBackupStore(serverID: server.id)) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your photos. Your server.", systemImage: "photo.on.rectangle.angled").font(.title2.bold())
                    Text("Copy photos, videos and Live Photo resources to \(server.name). Originals stay on your iPhone.").foregroundStyle(.secondary)
                }
                Section("Backup destination") {
                    if !backup.hasShareAccount { Text("Connect your share account in the Files tab first, then return here.") }
                    Button("Load my Unraid shares") { Task { await backup.loadShares() } }.disabled(backup.busy)
                    Picker("Share", selection: $backup.share) {
                        Text("Choose a share").tag("")
                        if !backup.share.isEmpty && !backup.shares.contains(backup.share) { Text(backup.share).tag(backup.share) }
                        ForEach(backup.shares, id: \.self) { Text($0).tag($0) }
                    }.disabled(backup.busy)
                    TextField("Backup folder", text: $backup.folder).disabled(backup.busy).autocorrectionDisabled()
                }
                Section("Photo access") {
                    Button("Allow Photos") { Task { await backup.allowPhotos() } }.disabled(backup.busy)
                    Text("\(backup.count) accessible photos and videos\(backup.limited ? " · Limited access" : "")")
                    Button("Change photo access in Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
                Section {
                    Text(backup.status)
                    if backup.backingUp { ProgressView(value: backup.progress); Text("\(backup.completed) of \(backup.total) items complete"); Button("Pause backup") { backup.pause() } }
                    else { Button("Back up now") { confirm = true }.buttonStyle(.borderedProminent).disabled(backup.busy || backup.share.isEmpty || backup.count == 0) }
                    if let error = backup.error { Text(error).foregroundStyle(.orange) }
                }
                Section {
                    Text("Keep the Photos screen open during backup. Leaving it pauses uploads; tap Back up now to continue. Completed items are skipped when their receipt and file sizes match. iCloud originals may need to download first and can use mobile data. Existing destination files are never overwritten.")
                    Text("This first version backs up files and edit resources, not album organization. It does not delete photos or provide a one-tap Photos-library restore.")
                }.font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Photos")
                .onChange(of: scenePhase) { _, phase in if phase == .background { backup.pause() }; if phase == .active { backup.refreshPhotoCount() } }
                .onDisappear { backup.pause() }
                .confirmationDialog("Back up \(backup.count) accessible items?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Test latest 5 items") { backup.start(limit: 5) }
                    Button("Back up all accessible items") { backup.start() }
                } message: { Text("Destination: \(backup.share)/\(backup.folder). Photos and videos will be uploaded; nothing on your phone will be deleted.") }
        }
    }
}

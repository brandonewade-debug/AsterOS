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
struct PhotoBackupCheckpoint: Codable {
    let share: String
    let folder: String
    let completed: Int
    let total: Int
    let finished: Bool
}
@MainActor enum PhotoDestinationPolicy {
    static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] } // The selected share root is a valid destination.
        return try path.split(separator: "/", omittingEmptySubsequences: false).map { try SharePolicy.name(String($0)) }
    }
    static func settingsKey(serverID: UUID, address: URL?, knownServerIDs: [UUID], defaults: UserDefaults) -> String {
        let legacy = "photoBackup-" + serverID.uuidString
        guard let address else { return legacy }
        let key = "photoBackupAddress-" + AppFoldersStore.addressKey(address)
        guard defaults.object(forKey: key) == nil else { return key }
        var source: String? = defaults.dictionary(forKey: legacy) != nil ? legacy : nil
        if source == nil, knownServerIDs == [serverID] {
            let candidates = defaults.dictionaryRepresentation().keys.filter { name in
                name.hasPrefix("photoBackup-") && UUID(uuidString: String(name.dropFirst("photoBackup-".count))) != nil && defaults.dictionary(forKey: name) != nil
            }
            if candidates.count == 1 { source = candidates[0] }
        }
        if let source {
            for suffix in ["", "-layout", "-timeZone", "-checkpoint"] {
                if let value = defaults.object(forKey: source + suffix) { defaults.set(value, forKey: key + suffix) }
            }
        }
        return key
    }
}
enum PhotoFolderLayout: String, CaseIterable, Identifiable {
    case monthly, daily
    var id: String { rawValue }
    var label: String { self == .monthly ? "Year → Month" : "Year → Month → Day" }
}
enum PhotoBackupPolicy {
    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func folders(date: Date?, layout: PhotoFolderLayout, timeZone: TimeZone) -> [String] {
        guard let date else { return ["Unknown date"] }
        let month = [format(date, "yyyy", timeZone: timeZone), format(date, "MM", timeZone: timeZone)]
        return layout == .monthly ? month : month + [format(date, "dd", timeZone: timeZone)]
    }
    static func destinations(date: Date?, layout: PhotoFolderLayout, isVideo: Bool, timeZone: TimeZone) -> [[String]] {
        let layouts = [layout] + PhotoFolderLayout.allCases.filter { $0 != layout }
        let dates = layouts.map { folders(date: date, layout: $0, timeZone: timeZone) }
        // Search the older mixed layout too; never re-upload just because organization changed.
        let candidates = dates.map { [isVideo ? "Videos" : "Photos"] + $0 } + dates
        return candidates.reduce(into: []) { result, path in if !result.contains(path) { result.append(path) } }
    }
    static func resourceName(date: Date?, originalName: String, identity: String, index: Int, timeZone: TimeZone) throws -> String {
        let original = try SharePolicy.name(originalName)
        let stamp = date.map { format($0, "yyyy-MM-dd HH-mm-ss", timeZone: timeZone) } ?? "Unknown date"
        return try SharePolicy.name("\(stamp) [\(identity.prefix(16))]-\(index)-\(original)")
    }
    static func identifier(_ localID: String, modified: Date?) -> String {
        SHA256.hash(data: Data("\(localID)|\(modified?.timeIntervalSince1970 ?? 0)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor final class PhotoBackupStore: ObservableObject {
    @Published var share = "" { didSet { saveDestination() } }
    @Published var folder = "AsterOS Photos" { didSet { saveDestination() } }
    @Published var layout: PhotoFolderLayout = .monthly {
        didSet { defaults.set(layout.rawValue, forKey: settingsKey + "-layout") }
    }
    @Published var shares: [String] = []
    @Published private(set) var folderEntries: [String] = []
    @Published private(set) var browsedPath: String?
    @Published private(set) var busy = false
    @Published private(set) var backingUp = false
    @Published private(set) var status = "Choose a backup destination" { didSet { reportExecution() } }
    @Published private(set) var backgroundStatus = ""
    @Published private(set) var count = 0
    @Published private(set) var completed = 0 { didSet { reportExecution() } }
    @Published private(set) var total = 0 { didSet { reportExecution() } }
    @Published private(set) var progress: Double = 0 { didSet { reportExecution() } }
    @Published private(set) var limited = false
    @Published var error: String?
    private let defaults: UserDefaults
    private let serverID: UUID
    private let serverAddress: URL?
    private var client: SMBClient?
    private var activeShareIdentity: (host: String, username: String)?
    private var watchdog: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var execution: PhotoBackupExecution?
    private var pauseReason = "Paused · tap Back up now to continue"
    private var paused = false
    private var timedOut = false
    private let settingsKey: String
    var hasShareAccount: Bool { ShareSettings.load(serverID: serverID, address: serverAddress, defaults: defaults) != nil }
    init(serverID: UUID, address: URL? = nil, knownServerIDs: [UUID] = [], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverID = serverID; self.serverAddress = address
        settingsKey = PhotoDestinationPolicy.settingsKey(serverID: serverID, address: address, knownServerIDs: knownServerIDs, defaults: defaults)
        if let saved = defaults.dictionary(forKey: settingsKey) as? [String: String] {
            share = saved["share"] ?? ""; folder = saved["folder"] ?? "AsterOS Photos"
        }
        layout = defaults.string(forKey: settingsKey + "-layout").flatMap(PhotoFolderLayout.init(rawValue:)) ?? .monthly
        restoreCheckpoint()
        refreshPhotoCount()
    }
    private func saveDestination() {
        guard !busy, (try? SharePolicy.name(share)) != nil, (try? PhotoDestinationPolicy.components(folder)) != nil else { return }
        defaults.set(["share": share, "folder": folder], forKey: settingsKey)
        restoreCheckpoint()
    }
    private func restoreCheckpoint() {
        completed = 0; total = 0; progress = 0
        status = "Choose a backup destination"
        if let data = defaults.data(forKey: settingsKey + "-checkpoint"),
           let saved = try? JSONDecoder().decode(PhotoBackupCheckpoint.self, from: data), saved.share == share, saved.folder == folder {
            completed = saved.completed; total = saved.total
            status = saved.finished ? "Last backup complete · \(saved.completed) items" : "Saved progress · \(saved.completed) of \(saved.total) items · tap Back up now to resume"
        }
    }
    private func saveCheckpoint(share: String, folder: String, finished: Bool = false) {
        let saved = PhotoBackupCheckpoint(share: share, folder: folder, completed: completed, total: total, finished: finished)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: settingsKey + "-checkpoint") }
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
        guard let connection = ShareSettings.load(serverID: serverID, address: serverAddress, defaults: defaults) else {
            throw AppError.message("Connect your Unraid share account in Files first, then return here.")
        }
        activeShareIdentity = (connection.host, connection.username)
        _ = try await TailnetStore.shared.prepare(for: connection.host)
        try check()
        let result = SMBClient(host: connection.host, port: 445, parameters: TailnetStore.shared.smbParameters())
        client = result; touch()
        try await result.login(username: connection.username, password: CredentialStore.read(connection.id), requireSigning: true)
        try check(); touch()
        return result
    }
    private func reportExecution() {
        execution?.update(completed: completed, total: total, fraction: progress, status: status)
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .active { refreshPhotoCount() }
        if phase == .background, backingUp, execution?.allowsBackground != true {
            pause(reason: "Paused by iOS · open AsterOS and tap Back up now to continue")
        }
    }
    private func finish() {
        execution?.finish(success: false); execution = nil
        watchdog?.cancel(); watchdog = nil; client?.session.disconnect(); client = nil; activeShareIdentity = nil
        busy = false; backingUp = false; task = nil
    }
    func loadShares() async {
        guard !busy else { return }
        busy = true; error = nil; paused = false; timedOut = false
        defer { finish() }
        do {
            let client = try await openShareClient()
            shares = try await client.listShares().filter { $0.type == .diskTree && (try? SharePolicy.name($0.name)) != nil }.map(\.name).sorted()
            if !share.isEmpty && !shares.contains(share) {
                error = "Your saved share is currently unavailable. Its destination and progress have been kept; check the share account permissions."
            }
        } catch { self.error = error.localizedDescription }
    }
    func listFolders(path: String) async {
        guard !busy else { return }
        busy = true; error = nil; paused = false; timedOut = false
        browsedPath = nil; folderEntries = []
        defer { finish() }
        do {
            _ = try SharePolicy.name(share)
            _ = try PhotoDestinationPolicy.components(path)
            let client = try await openShareClient()
            try await client.connectShare(share); try check(); touch()
            let entries = try await client.listDirectory(path: path)
            try check()
            folderEntries = entries.filter { $0.isDirectory && (try? SharePolicy.name($0.name)) != nil }.map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            browsedPath = path
        } catch { self.error = error.localizedDescription }
    }
    func start(limit: Int? = nil, verifyExisting: Bool = false) {
        guard !busy else { return }
        runID = UUID()
        busy = true; backingUp = true; paused = false; timedOut = false; error = nil; completed = 0; total = 0; progress = 0
        let destinationShare = share, destinationFolder = folder
        let destinationLayout = layout
        status = "Preparing backup…"; backgroundStatus = "Requesting background backup…"
        execution = PhotoBackupExecution(stop: { [weak self] in
            self?.pause(reason: "Paused by iOS or system Stop · tap Back up now to continue")
        }, report: { [weak self] in self?.backgroundStatus = $0 })
        task = Task { await backup(share: destinationShare, folder: destinationFolder, layout: destinationLayout, limit: limit, verifyExisting: verifyExisting) }
    }
    func pause(reason: String = "Paused · tap Back up now to continue") {
        guard backingUp else { return }
        pauseReason = reason
        paused = true; status = "Pausing…"; task?.cancel(); client?.session.disconnect()
    }
    private func backup(share: String, folder: String, layout: PhotoFolderLayout, limit: Int?, verifyExisting: Bool) async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("asteros-photos-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary); finish() }
        do {
            _ = try SharePolicy.name(share); let rootComponents = try PhotoDestinationPolicy.components(folder)
            let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard auth == .authorized || auth == .limited else { throw AppError.message("Tap Allow Photos before starting backup.") }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let client = try await openShareClient()
            try await client.connectShare(share); try check(); touch()
            var rootPath = ""
            for component in rootComponents {
                try check(); touch()
                let children = try await client.listDirectory(path: rootPath)
                let next = try SharePolicy.child(component, in: rootPath)
                if let existing = children.first(where: { $0.name == component }) {
                    guard existing.isDirectory else { throw AppError.message("The backup folder path is already used by a file.") }
                } else { try await client.createDirectory(path: next) }
                rootPath = next
            }
            defaults.set(["share": share, "folder": folder], forKey: settingsKey)
            let folders = try await client.listDirectory(path: folder)
            // One small destination marker protects against accidentally trusting a
            // journal for a newly created/replaced backup root.
            let markerName = ".asteros-backup-id"
            let markerPath = folder.isEmpty ? markerName : folder + "/" + markerName
            let marker: String
            if let entry = folders.first(where: { $0.name == markerName }) {
                guard !entry.isDirectory, entry.size <= 128 else { throw AppError.message("The backup destination marker is invalid.") }
                let reader = client.fileReader(path: markerPath)
                let data: Data
                do { data = try await reader.read(offset: 0, length: 128); try await reader.close() }
                catch { try? await reader.close(); throw error }
                guard let value = String(data: data, encoding: .utf8), let uuid = UUID(uuidString: value) else { throw AppError.message("The backup destination marker is invalid.") }
                marker = uuid.uuidString
            } else {
                marker = UUID().uuidString
                let file = temporary.appendingPathComponent("destination-id")
                let data = Data(marker.utf8); try data.write(to: file, options: .atomic)
                try await upload(file, to: markerPath, client: client, size: UInt64(data.count))
            }
            guard let connection = activeShareIdentity else { throw AppError.message("Reconnect your share account before backing up.") }
            let scope = PhotoBackupIndex.scope(server: settingsKey, host: connection.host, account: connection.username, share: share, folder: folder, marker: marker)
            let journal = try PhotoBackupIndex(scope: scope, reset: verifyExisting)
            let legacyFolders = Set(folders.filter(\.isDirectory).map(\.name))
            var cachedFolders: [String: Set<String>] = [folder: legacyFolders]
            var cachedSizes: [String: [String: UInt64]] = [:]
            let timeZoneKey = settingsKey + "-timeZone"
            let timeZone = defaults.string(forKey: timeZoneKey).flatMap(TimeZone.init(identifier:)) ?? .current
            defaults.set(timeZone.identifier, forKey: timeZoneKey)
            let fetched = assets(); count = fetched.count
            total = min(count, max(0, limit ?? count))
            status = verifyExisting ? "Verifying existing backup…" : "Finding new photos on this device…"
            var pending: [(index: Int, identity: String)] = []
            var locallyCompleted = 0
            // Local-only lookups: no exports, remote stats, or receipt reads for
            // items already committed by this device to this destination.
            for index in 0..<total {
                if index % 128 == 0 { await Task.yield(); try check() }
                let asset = fetched.object(at: fetched.count - total + index)
                let identity = PhotoBackupPolicy.identifier(asset.localIdentifier, modified: asset.modificationDate)
                if journal.contains(identity) { locallyCompleted += 1 }
                else { pending.append((index, identity)) }
            }
            completed = locallyCompleted
            progress = 0
            saveCheckpoint(share: share, folder: folder)
            for (index, identity) in pending {
                try check(); touch()
                let asset = fetched.object(at: fetched.count - total + index)
                let resources = PHAssetResource.assetResources(for: asset)
                guard !resources.isEmpty else { throw AppError.message("Photos did not provide the original resources for an item.") }
                let legacy = legacyFolders.contains(identity)
                let destinations = PhotoBackupPolicy.destinations(date: asset.creationDate, layout: layout, isVideo: asset.mediaType == .video, timeZone: timeZone)
                var components = legacy ? [identity] : destinations[0]
                let receiptName = legacy ? "complete.json" : ".asteros-" + identity + ".json"
                // Find completed or interrupted backups in either layout before creating anything.
                if !legacy {
                    for candidate in destinations {
                        var candidatePath = folder
                        var found = true
                        for component in candidate {
                            if cachedFolders[candidatePath] == nil {
                                cachedFolders[candidatePath] = Set(try await client.listDirectory(path: candidatePath).filter(\.isDirectory).map(\.name))
                            }
                            guard cachedFolders[candidatePath, default: []].contains(component) else { found = false; break }
                            candidatePath = try SharePolicy.child(component, in: candidatePath)
                        }
                        if found {
                            if cachedSizes[candidatePath] == nil {
                                cachedSizes[candidatePath] = Dictionary(try await client.listDirectory(path: candidatePath).filter { !$0.isDirectory }.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
                            }
                            let firstName = try PhotoBackupPolicy.resourceName(date: asset.creationDate, originalName: resources[0].originalFilename, identity: identity, index: 0, timeZone: timeZone)
                            if cachedSizes[candidatePath]?[receiptName] != nil || cachedSizes[candidatePath]?[firstName] != nil {
                                components = candidate; break
                            }
                        }
                    }
                }
                var path = folder
                status = "Checking item \(index + 1) of \(total)"
                for component in components {
                    try check(); touch()
                    if cachedFolders[path] == nil { cachedFolders[path] = Set(try await client.listDirectory(path: path).filter(\.isDirectory).map(\.name)) }
                    let next = try SharePolicy.child(component, in: path)
                    if !cachedFolders[path, default: []].contains(component) {
                        try await client.createDirectory(path: next)
                        cachedFolders[path, default: []].insert(component)
                        cachedFolders[next] = []
                    }
                    path = next
                }
                if cachedSizes[path] == nil {
                    cachedSizes[path] = Dictionary(try await client.listDirectory(path: path).filter { !$0.isDirectory }.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
                }
                let sizes = cachedSizes[path] ?? [:]
                if let receiptSize = sizes[receiptName] {
                    guard receiptSize < 1_000_000 else { throw AppError.message("An existing backup receipt is invalid. Choose a new backup folder.") }
                    let reader = client.fileReader(path: path + "/" + receiptName)
                    let bytes: Data
                    do { bytes = try await reader.read(offset: 0, length: 1_000_000); try await reader.close() }
                    catch { try? await reader.close(); throw error }
                    guard let receipt = try? JSONDecoder().decode(PhotoBackupReceipt.self, from: bytes), receipt.matches(sizes, asset: identity) else {
                        throw AppError.message("A previous backup is missing files or has changed. Choose a new folder to make another complete copy; existing files were left untouched.")
                    }
                    try check()
                    try journal.record(identity)
                    progress = 0; completed += 1
                    saveCheckpoint(share: share, folder: folder)
                    continue
                }
                // Export every available resource: originals, Live Photo video and edit resources.
                var records: [PhotoBackupReceipt.Resource] = []
                for (resourceIndex, resource) in resources.enumerated() {
                    try check()
                    let original = try SharePolicy.name(resource.originalFilename)
                    let name = try legacy ? SharePolicy.name("\(resourceIndex)-" + original) : PhotoBackupPolicy.resourceName(date: asset.creationDate, originalName: original, identity: identity, index: resourceIndex, timeZone: timeZone)
                    let file = temporary.appendingPathComponent(UUID().uuidString)
                    status = "Preparing \(index + 1) of \(total) from Photos…"; progress = 0
                    watchdog?.cancel()
                    try await PhotoResourceExport.write(resource, to: file)
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
                try await upload(file, to: path + "/" + receiptName, client: client, size: UInt64(encoded.count))
                for record in records { cachedSizes[path, default: [:]][record.name] = record.size }
                cachedSizes[path, default: [:]][receiptName] = UInt64(encoded.count)
                try journal.record(identity)
                progress = 0; completed += 1
                saveCheckpoint(share: share, folder: folder)
            }
            saveCheckpoint(share: share, folder: folder, finished: true)
            progress = 1; status = "Backup complete · \(completed) items"
            execution?.finish(success: true)
        } catch {
            if paused || error is CancellationError { status = pauseReason }
            else { status = "Backup stopped"; self.error = error.localizedDescription }
        }
    }
    private func upload(_ file: URL, to destination: String, client: SMBClient, size: UInt64) async throws {
        let parent = destination.split(separator: "/").dropLast().joined(separator: "/")
        let staging = (parent.isEmpty ? "" : parent + "/") + ".asteros-upload-" + UUID().uuidString
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let writer = client.fileWriter(path: staging)
        do {
            touch()
            let uploadRun = runID
            try await writer.upload(fileHandle: handle) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.runID == uploadRun, self.backingUp, !self.paused else { return }
                    self.progress = value; self.touch()
                }
            }
            try await writer.close(); try check(); touch()
            let reader = client.fileReader(path: staging)
            let written: UInt64
            do {
                written = try await reader.fileSize
                guard written == size else { throw AppError.message("The server did not receive the complete file. Retry backup.") }
                // Read back the staging file before committing it or writing a completion receipt.
                try handle.seek(toOffset: 0)
                try await BackupVerification.verify(size: size, readLocal: { count in
                    try handle.read(upToCount: count) ?? Data()
                }, readRemote: { offset, count in
                    try self.check(); self.touch()
                    return try await reader.read(offset: offset, length: UInt32(count))
                })
                try await reader.close()
            } catch { try? await reader.close(); throw error }
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
        if let server = app.selected, !app.demo { PhotoBackupView(server: server, backup: app.photoBackup(for: server)).id("photos-" + server.id.uuidString + "-\(app.preferencesRevision)") }
        else { NavigationStack { ContentUnavailableView("Connect your server", systemImage: "photo", description: Text("Connect Unraid to set up photo backup to one of its shares.")).navigationTitle("Photos") } }
    }
}
struct PhotoBackupView: View {
    let server: ServerProfile
    @ObservedObject var backup: PhotoBackupStore
    @Environment(\.openURL) private var openURL
    @State private var confirm = false
    @State private var choosingFolder = false
    @State private var confirmVerification = false
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    Label("Your photos. Your server.", systemImage: "photo.on.rectangle.angled").font(.title2.bold())
                    Text("Copy photos, videos and Live Photo resources to \(server.name). Uploads are verified before completion. Originals stay on your iPhone.").foregroundStyle(.secondary)
                }
                Section("Backup destination") {
                    if !backup.hasShareAccount { Text("Connect your share account in the Files tab first, then return here.") }
                    Button("Load my Unraid shares") { Task { await backup.loadShares() } }.disabled(backup.busy)
                    Picker("Share", selection: $backup.share) {
                        Text("Choose a share").tag("")
                        if !backup.share.isEmpty && !backup.shares.contains(backup.share) { Text(backup.share).tag(backup.share) }
                        ForEach(backup.shares, id: \.self) { Text($0).tag($0) }
                    }.disabled(backup.busy)
                    Button { choosingFolder = true } label: {
                        Label(backup.folder.isEmpty ? "Share root" : backup.folder, systemImage: "folder")
                    }.disabled(backup.busy || backup.share.isEmpty)
                    Text("Tap the folder to browse your share. To resume, choose the original backup folder containing Photos/Videos or the older year folders.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("New folder or manual path") {
                        TextField("Folder path inside share", text: $backup.folder).disabled(backup.busy).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Text("New folders are created when backup starts. Leave blank to use the share root.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Organize by", selection: $backup.layout) {
                        ForEach(PhotoFolderLayout.allCases) { Text($0.label).tag($0) }
                    }.disabled(backup.busy)
                    Text("Separate Photos and Videos folders each contain Year → Month, with optional day folders. Live Photo video components stay in Photos with their image. Filenames start with capture date and time, so name sorting keeps each month in day order. They also include a short identifier and the original name. Live Photo components share the same identifier.").font(.caption).foregroundStyle(.secondary)
                    Text("Progress is saved after each completed item. Restart the app and tap Back up now to resume: verified completed items are skipped. Existing backups keep their current locations, including videos already in mixed folders.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Photo access") {
                    Button("Allow Photos") { Task { await backup.allowPhotos() } }.disabled(backup.busy)
                    Text("\(backup.count) accessible photos and videos\(backup.limited ? " · Limited access" : "")")
                    Button("Change photo access in Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
                Section {
                    Text(backup.status)
                    if backup.backingUp { Text(backup.backgroundStatus).font(.caption).foregroundStyle(.secondary) }
                    if backup.backingUp { ProgressView(value: backup.progress); Text("\(backup.completed) of \(backup.total) items complete"); Button("Pause backup") { backup.pause() } }
                    else { Button("Back up now") { confirm = true }.buttonStyle(.borderedProminent).disabled(backup.busy || backup.share.isEmpty || backup.count == 0) }
                    Button("Verify existing backup") { confirmVerification = true }.disabled(backup.busy || backup.share.isEmpty || backup.count == 0)
                    if let error = backup.error { Text(error).foregroundStyle(.orange) }
                }
                Section {
                    Text("Backup continues while you use other tabs. On iOS 26, AsterOS requests background processing when you start a backup. iOS can pause it for resource limits or when you tap Stop; force-closing AsterOS stops it. Older iOS versions allow only limited background time. Open AsterOS and tap Back up now to resume.")
                    Text("Completed items are remembered on this device, so normal resume checks only new or changed items. The first run after this update imports older receipts once. Use Verify existing backup after changing files on the server; it rereads receipts and file sizes and may take time. New uploads are still read back before being marked complete. iCloud originals may download first and can use mobile data. Existing files are never overwritten.")
                    Text("This first version backs up files and edit resources, not album organization. It does not delete photos or provide a one-tap Photos-library restore.")
                }.font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Photos")
                .sheet(isPresented: $choosingFolder) { PhotoBackupFolderPicker(backup: backup) }
                .onChange(of: backup.share) { _, share in if !share.isEmpty { choosingFolder = true } }
                .onAppear { backup.refreshPhotoCount() }
                .confirmationDialog("Verify every existing backup item?", isPresented: $confirmVerification, titleVisibility: .visible) {
                    Button("Verify and resume backup") { backup.start(verifyExisting: true) }
                } message: { Text("This rebuilds the local completion index by reading server receipts and checking file sizes. For a large library it can take time. Normal Back up now skips this scan.") }
                .confirmationDialog("Back up \(backup.count) accessible items?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Test latest 5 items") { backup.start(limit: 5) }
                    Button("Back up all accessible items") { backup.start() }
                } message: { Text("Destination: \(backup.share)/\(backup.folder). Photos and videos will be uploaded; nothing on your phone will be deleted.") }
        }
    }
}

struct PhotoBackupFolderPicker: View {
    @ObservedObject var backup: PhotoBackupStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GlassForm {
                Section {
                    Label(backup.share + (backup.browsedPath.flatMap { $0.isEmpty ? nil : "/" + $0 } ?? ""), systemImage: "externaldrive").font(.headline)
                    Text("Choose the original backup root to continue an existing backup. Completed items are verified and skipped.").font(.caption).foregroundStyle(.secondary)
                    if backup.busy { ProgressView("Loading folders…") }
                    if let error = backup.error { Text(error).foregroundStyle(.orange) }
                    if let path = backup.browsedPath, !path.isEmpty {
                        Button("Parent folder", systemImage: "chevron.up") {
                            Task { await backup.listFolders(path: path.split(separator: "/").dropLast().joined(separator: "/")) }
                        }.disabled(backup.busy)
                    }
                    Button("Share root", systemImage: "house") { Task { await backup.listFolders(path: "") } }.disabled(backup.busy)
                }
                Section("Folders") {
                    ForEach(backup.folderEntries, id: \.self) { name in
                        Button { if let path = backup.browsedPath, let next = try? SharePolicy.child(name, in: path) { Task { await backup.listFolders(path: next) } } } label: {
                            HStack { Label(name, systemImage: "folder.fill"); Spacer(); Image(systemName: "chevron.right") }
                        }.disabled(backup.busy)
                    }
                    if !backup.busy && backup.browsedPath != nil && backup.folderEntries.isEmpty { Text("No subfolders").foregroundStyle(.secondary) }
                }
                Section {
                    Button("Use this folder") { if let path = backup.browsedPath { backup.folder = path; dismiss() } }
                        .buttonStyle(.borderedProminent).disabled(backup.busy || backup.browsedPath == nil)
                }
            }.navigationTitle("Choose backup folder").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() }.disabled(backup.busy) }
                .interactiveDismissDisabled(backup.busy)
                .task { await backup.listFolders(path: "") }
        }
    }
}

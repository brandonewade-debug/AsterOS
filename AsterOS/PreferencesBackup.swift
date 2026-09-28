import SwiftUI
import UniformTypeIdentifiers

struct PreferencesArchive: Codable {
    var version = 1
    var folders: AppFolderLayout
    var apps: [SavedApp]
    var photoShare: String?
    var photoFolder: String?
    var photoLayout: String
    var photoTimeZone: String?
    var terminalFont: Int

    @MainActor func validate() throws {
        func text(_ value: String, limit: Int = 300) -> Bool {
            value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        func identity(_ value: String) -> Bool {
            guard text(value) else { return false }
            if value == "catalog" { return true }
            if value.hasPrefix("container:") { return value.count > 10 }
            for prefix in ["shortcut:", "folder:"] where value.hasPrefix(prefix) {
                return UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
            }
            return false
        }
        guard version == 1, apps.count <= 200, folders.folders.count <= 100,
              folders.order.count <= 2000, Set(folders.order).count == folders.order.count,
              folders.order.allSatisfy(identity), Set(apps.map(\.id)).count == apps.count,
              Set(folders.folders.map(\.id)).count == folders.folders.count,
              (12...24).contains(terminalFont), PhotoFolderLayout(rawValue: photoLayout) != nil else {
            throw AppError.message("This preferences file is unsupported or contains invalid values. Nothing was imported.")
        }
        var membership = Set<String>()
        for folder in folders.folders {
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, folder.name.count <= 60, text(folder.name, limit: 240), folder.members.count <= 2000 else { throw AppError.message("Invalid app folder in preferences file.") }
            for member in folder.members {
                guard identity(member), member.hasPrefix("container:") || member.hasPrefix("shortcut:"), membership.insert(member).inserted else { throw AppError.message("Invalid or duplicate folder member in preferences file.") }
            }
        }
        for app in apps {
            if app.url.scheme?.lowercased() == "http",
               let host = app.url.host, TailnetPolicy.contains(host), AppWebPolicy.allows(app.url) {
                // Importing a saved route never grants access; BrowserModel verifies the live peer.
            } else { _ = try AddressPolicy.validate(app.url.absoluteString) }
            guard text(app.name), text(app.symbol, limit: 100), app.url.absoluteString.utf8.count <= 4096,
                  app.containerID.map({ text($0) }) ?? true else { throw AppError.message("Invalid app shortcut in preferences file.") }
        }
        if let photoShare, !photoShare.isEmpty { _ = try SharePolicy.name(photoShare) }
        if let photoFolder { _ = try PhotoDestinationPolicy.components(photoFolder); guard text(photoFolder, limit: 4096) else { throw AppError.message("Invalid backup path.") } }
        if let photoTimeZone, TimeZone(identifier: photoTimeZone) == nil { throw AppError.message("Invalid photo time zone.") }
        guard (photoShare == nil) == (photoFolder == nil) else { throw AppError.message("Incomplete photo destination.") }
    }
    @MainActor static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw AppError.message("Preferences files must be smaller than 2 MB.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(); return result
    }
    @MainActor static func capture(server: ServerProfile, defaults: UserDefaults = .standard) throws -> Self {
        let folders = AppFoldersStore(defaults: defaults)
        folders.load(serverID: server.id, address: server.address)
        guard folders.error == nil else { throw AppError.message("Saved app folders could not be read. They have not been changed.") }
        let key = PhotoDestinationPolicy.settingsKey(serverID: server.id, address: server.address, knownServerIDs: [], defaults: defaults)
        let destination = defaults.dictionary(forKey: key) as? [String: String]
        let font = defaults.integer(forKey: "terminalFontSize")
        let result = Self(folders: folders.layout, apps: server.apps, photoShare: destination?["share"], photoFolder: destination?["folder"], photoLayout: defaults.string(forKey: key + "-layout") ?? "monthly", photoTimeZone: defaults.string(forKey: key + "-timeZone"), terminalFont: font == 0 ? 15 : font)
        try result.validate(); return result
    }
    @MainActor func apply(to server: ServerProfile, defaults: UserDefaults = .standard) throws {
        // All decoding/validation/encoding completes before any settings are replaced.
        try validate()
        let encoded = try JSONEncoder().encode(folders)
        let previous = try JSONEncoder().encode(Self.capture(server: server, defaults: defaults))
        let key = "photoBackupAddress-" + AppFoldersStore.addressKey(server.address)
        defaults.set(previous, forKey: "preferencesRecovery-" + AppFoldersStore.addressKey(server.address))
        defaults.set(encoded, forKey: AppFoldersStore.addressKey(server.address))
        defaults.set(encoded, forKey: "appFolders-" + server.id.uuidString)
        if let photoShare, let photoFolder { defaults.set(["share": photoShare, "folder": photoFolder], forKey: key) }
        else { defaults.removeObject(forKey: key) }
        defaults.set(photoLayout, forKey: key + "-layout")
        defaults.set(photoTimeZone, forKey: key + "-timeZone")
        defaults.removeObject(forKey: key + "-checkpoint")
        defaults.set(terminalFont, forKey: "terminalFontSize")
    }
}
struct PreferencesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct PreferencesBackupView: View {
    @EnvironmentObject var store: AppStore
    let server: ServerProfile
    @State private var exporting = false
    @State private var importing = false
    @State private var document = PreferencesDocument(data: Data())
    @State private var pending: PreferencesArchive?
    @State private var confirming = false
    @State private var message: String?
    private func export() {
        do {
            guard store.selectedID == server.id, let current = store.selected else { throw AppError.message("The selected server changed. Open preferences backup again.") }
            let archive = try PreferencesArchive.capture(server: current)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            document = PreferencesDocument(data: try encoder.encode(archive)); exporting = true
        } catch { message = error.localizedDescription }
    }
    var body: some View {
        GlassForm {
            Section("Save your setup") {
                Text("Export app folders and order, external shortcuts, photo backup destination and organization, and terminal text size for this server.")
                Text("This file contains app names, shortcut URLs and folder paths. Store it privately. Credentials, PIN, Tailscale identity, custom icon images and photo completion receipts are not included. Backup receipts remain alongside your photos on the server.").font(.caption).foregroundStyle(.secondary)
                Button("Export preferences", systemImage: "square.and.arrow.up") { export() }
                Button("Import preferences", systemImage: "square.and.arrow.down") { importing = true }
            }
            Section {
                Text("Import replaces these preferences on the selected server. It does not connect a new server, change security, or start a backup. Select the original photo destination to resume using its completion receipts.").font(.caption).foregroundStyle(.secondary)
                Button("Restore preferences from before last import") {
                    do {
                        guard let data = UserDefaults.standard.data(forKey: "preferencesRecovery-" + AppFoldersStore.addressKey(server.address)) else { throw AppError.message("No previous import to undo.") }
                        pending = try PreferencesArchive.decode(data); confirming = true
                    } catch { message = error.localizedDescription }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }.navigationTitle("Preferences backup")
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "AsterOS-preferences") { result in
                if case .failure = result { message = "Preferences could not be exported. Please try again." }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                    let data = try file.read(upToCount: 2_000_001) ?? Data()
                    pending = try PreferencesArchive.decode(data); confirming = true
                } catch { message = "Could not import preferences: " + error.localizedDescription }
            }
            .confirmationDialog("Replace preferences for \(server.name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Replace preferences", role: .destructive) {
                    do {
                        guard let pending, store.selectedID == server.id else { throw AppError.message("The selected server changed. Open preferences backup again.") }
                        try store.importPreferences(pending, serverID: server.id)
                        message = "Preferences restored. Existing server receipts will be checked when you start photo backup."
                        self.pending = nil
                    } catch { message = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text("\(pending?.folders.folders.count ?? 0) app folders and \(pending?.apps.count ?? 0) shortcuts. Photo destination: \(pending?.photoShare ?? "not set") / \(pending?.photoFolder ?? ""). Your current preferences are kept for undo.")
            }
    }
}

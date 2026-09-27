import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import ImageIO

struct CustomIconTarget: Identifiable {
    let app: String
    let name: String
    let server: URL
    var id: String { server.absoluteString + "|" + app }
}

@MainActor final class CustomIconsStore: ObservableObject {
    static let shared = CustomIconsStore()
    @Published private(set) var revision = 0
    private let directory: URL
    private let cache = NSCache<NSString, UIImage>()
    private var missing = Set<String>()
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CustomAppIcons", isDirectory: true)
        cache.countLimit = 40; cache.totalCostLimit = 32 * 1024 * 1024
    }
    private func key(app: String, server: URL) -> String {
        let identity = AppFoldersStore.addressKey(server) + "\n" + app
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func image(app: String, server: URL) -> UIImage? {
        let key = key(app: app, server: server)
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !missing.contains(key) else { return nil }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(key + ".png").path) else {
            missing.insert(key); return nil
        }
        cache.setObject(image, forKey: key as NSString, cost: 512 * 512 * 4)
        return image
    }
    func save(_ image: UIImage, fill: Bool, app: String, server: URL) throws {
        let normalized = Self.square(image, fill: fill)
        guard let data = normalized.pngData() else { throw AppError.message("This image could not be saved.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = key(app: app, server: server)
        try data.write(to: directory.appendingPathComponent(key + ".png"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cache.setObject(normalized, forKey: key as NSString, cost: 512 * 512 * 4); missing.remove(key); revision += 1
    }
    func remove(app: String, server: URL) throws {
        let key = key(app: app, server: server)
        let file = directory.appendingPathComponent(key + ".png")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        cache.removeObject(forKey: key as NSString); missing.insert(key); revision += 1
    }
    static func decode(_ data: Data) throws -> UIImage {
        guard !data.isEmpty, data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw AppError.message("Choose a supported image under 20 MB, such as PNG, JPEG or HEIC.")
        }
        return UIImage(cgImage: thumbnail)
    }
    static func square(_ image: UIImage, fill: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in
            let scale = fill ? max(512 / image.size.width, 512 / image.size.height) : min(512 / image.size.width, 512 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

struct CustomIconEditor: View {
    let target: CustomIconTarget
    @ObservedObject private var icons = CustomIconsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var filePicker = false
    @State private var draft: UIImage?
    @State private var fill = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Group {
                        if let image = draft ?? icons.image(app: target.app, server: target.server) {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                        } else {
                            Image(systemName: "photo.badge.plus").font(.system(size: 50)).foregroundStyle(.mint)
                        }
                    }.frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
                        .accessibilityLabel("Icon preview for " + target.name)
                    Text(target.name).font(.title2.bold())
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo")
                    }.buttonStyle(.bordered).disabled(busy)
                    Button { filePicker = true } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }.buttonStyle(.bordered).disabled(busy)
                    if draft != nil {
                        Picker("Image fit", selection: $fill) {
                            Text("Fit").tag(false)
                            Text("Fill").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if busy { ProgressView("Loading image…") }
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                    Text("Saved in AsterOS on this device. Your container and its original icon are unchanged.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if icons.image(app: target.app, server: target.server) != nil {
                        Button("Restore original icon", role: .destructive) {
                            do { try icons.remove(app: target.app, server: target.server); dismiss() }
                            catch { self.error = "Could not restore the original icon. Try again." }
                        }.disabled(busy)
                    }
                }.padding(28).frame(maxWidth: 500).frame(maxWidth: .infinity)
            }.background { AsterBackdrop() }
                .navigationTitle("App icon").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            guard let draft else { return }
                            do { try icons.save(draft, fill: fill, app: target.app, server: target.server); dismiss() }
                            catch { self.error = "Could not save this icon. Check available device storage and try again." }
                        }.disabled(draft == nil || busy)
                    }
                }
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.image]) { result in
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 20_000_000 else { throw AppError.message("Choose an image under 20 MB.") }
                        draft = try CustomIconsStore.decode(Data(contentsOf: url, options: .mappedIfSafe))
                        fill = false; error = nil
                    } catch { self.error = error.localizedDescription }
                }
                .task(id: photo) {
                    guard let photo else { return }
                    busy = true; error = nil
                    defer { busy = false }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self) else { throw AppError.message("This photo could not be loaded.") }
                        try Task.checkCancellation()
                        draft = try CustomIconsStore.decode(data); fill = false
                    } catch is CancellationError { }
                    catch { self.error = error.localizedDescription }
                }
        }
    }
}


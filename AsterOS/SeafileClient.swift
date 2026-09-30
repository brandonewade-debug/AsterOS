import Foundation

struct SeafileConnection: Codable {
    var id = UUID()
    let address: URL
}
@MainActor enum SeafileSettings {
    static func key(_ server: URL) -> String { "seafile-" + AppFoldersStore.addressKey(server) }
    static func load(_ server: URL) -> SeafileConnection? {
        guard let data = UserDefaults.standard.data(forKey: key(server)) else { return nil }
        return try? JSONDecoder().decode(SeafileConnection.self, from: data)
    }
    static func forget(_ server: URL) throws {
        if let saved = load(server) { try CredentialStore.remove(saved.id) }
        UserDefaults.standard.removeObject(forKey: key(server))
    }
    static func save(_ connection: SeafileConnection, token: String, server: URL) throws {
        let old = load(server)
        try CredentialStore.save(token, for: connection.id)
        UserDefaults.standard.set(try JSONEncoder().encode(connection), forKey: key(server))
        if let old, old.id != connection.id { try? CredentialStore.remove(old.id) }
    }
}
struct SeafileLibrary: Decodable, Identifiable {
    let id: String
    let name: String
    let permission: String?
    let encrypted: Bool
    var writable: Bool { permission == "rw" && !encrypted }
    enum CodingKeys: String, CodingKey { case id, name, permission, encrypted }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard UUID(uuidString: id) != nil else { throw AppError.message("Seafile returned an invalid library identifier.") }
        name = try c.decode(String.self, forKey: .name)
        permission = try c.decodeIfPresent(String.self, forKey: .permission)
        if let flag = try? c.decode(Bool.self, forKey: .encrypted) { encrypted = flag }
        else if let flag = try? c.decode(Int.self, forKey: .encrypted) { encrypted = flag != 0 }
        else { encrypted = true } // Unknown encryption state must not grant access.
    }
}
struct SeafileEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
    let size: UInt64?
    var isDirectory: Bool { type == "dir" }
}
@MainActor enum SeafilePolicy {
    static func address(_ input: String) throws -> URL {
        let url = try AddressPolicy.validate(input)
        guard url.path.isEmpty || url.path == "/" else { throw AppError.message("Enter the Seafile server address without a library or file path.") }
        return url
    }
    static func transferURL(_ input: String, base: URL) throws -> URL {
        guard let url = URL(string: input, relativeTo: base)?.absoluteURL,
              url.user == nil, url.password == nil, url.fragment == nil,
              LocalHTTPPolicy.permits(url), LocalHTTPPolicy.origin(url) == LocalHTTPPolicy.origin(base) else {
            throw AppError.message("Seafile returned a file address on a different or insecure server. Check Seafile’s file-server URL configuration.")
        }
        return url
    }
    static func path(_ path: String) throws -> String {
        _ = try PhotoDestinationPolicy.components(path)
        return "/" + path
    }
}
final class SeafileSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { progress(totalBytesExpectedToSend > 0 ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}
@MainActor final class SeafileClient {
    let connection: SeafileConnection
    private let token: String
    private let session: URLSession
    private var library: String?
    var activity: (@MainActor () -> Void)?
    init(connection: SeafileConnection, token: String) {
        self.connection = connection; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        config.allowsCellularAccess = connection.address.scheme == "https"
        session = URLSession(configuration: config, delegate: SeafileSessionDelegate(progress: { _ in }), delegateQueue: nil)
    }
    func disconnect() { session.invalidateAndCancel() }
    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        _ = try SeafilePolicy.address(connection.address.absoluteString)
        var c = URLComponents(url: connection.address.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }
    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw AppError.message("Invalid Seafile response.") }
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401: throw AppError.message("Seafile rejected the sign-in or token. Check your account details and two-factor code, or reconnect Seafile in Files.")
            case 403: throw AppError.message("Your Seafile account does not have permission for this operation.")
            case 404: throw AppError.message("This Seafile library or folder is unavailable. Your saved destination has been kept.")
            case 413: throw AppError.message("This file exceeds your Seafile server’s upload limit.")
            default: throw AppError.message("Seafile request failed (HTTP \(response.statusCode)). Check the server and try again.")
            }
        }
    }
    private func request(_ path: String, query: [URLQueryItem] = [], form: [String: String]? = nil, otp: String? = nil) async throws -> Data {
        var request = URLRequest(url: try endpoint(path, query: query))
        if !token.isEmpty { request.setValue("Token " + token, forHTTPHeaderField: "Authorization") }
        if let otp, !otp.isEmpty { request.setValue(otp, forHTTPHeaderField: "X-SEAFILE-OTP") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.httpMethod = "POST"
            var encoded = URLComponents(); encoded.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = encoded.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try check(response); activity?(); return data
    }
    func signIn(email: String, password: String, otp: String) async throws -> String {
        struct Authentication: Decodable { let token: String }
        let result = try JSONDecoder().decode(Authentication.self, from: await request("api2/auth-token/", form: ["username": email, "password": password], otp: otp))
        guard !result.token.isEmpty else { throw AppError.message("Seafile did not return a sign-in token.") }
        return result.token
    }
    func libraries() async throws -> [SeafileLibrary] {
        try JSONDecoder().decode([SeafileLibrary].self, from: await request("api2/repos/"))
    }
    func select(_ id: String, writing: Bool = false) async throws {
        guard let item = try await libraries().first(where: { $0.id == id }), !item.encrypted else { throw AppError.message("Choose an unencrypted Seafile library. Encrypted libraries are not supported yet.") }
        if writing && !item.writable { throw AppError.message("Choose a Seafile library with read/write permission.") }
        library = id
    }
    private func repo(_ suffix: String) throws -> String {
        guard let library else { throw AppError.message("Choose a Seafile library first.") }
        return "api2/repos/\(library)/\(suffix)/"
    }
    func list(_ path: String) async throws -> [SeafileEntry] {
        try JSONDecoder().decode([SeafileEntry].self, from: await request(repo("dir"), query: [.init(name: "p", value: SeafilePolicy.path(path))]))
    }
    func mkdir(_ path: String) async throws {
        _ = try await request(repo("dir"), query: [.init(name: "p", value: SeafilePolicy.path(path)), .init(name: "reloaddir", value: "true")], form: ["operation": "mkdir"])
    }
    func download(_ path: String) async throws -> URL {
        let link = try JSONDecoder().decode(String.self, from: await request(repo("file"), query: [.init(name: "p", value: SeafilePolicy.path(path))]))
        let url = try SeafilePolicy.transferURL(link, base: connection.address)
        // The temporary file URL is already authorized; never attach the account token.
        let delegate = SeafileSessionDelegate { [weak self] _ in Task { @MainActor in self?.activity?() } }
        let (file, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        try check(response)
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("asteros-seafile-" + UUID().uuidString)
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: saved.path)
        return saved
    }
    func upload(_ handle: FileHandle, path: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let name = try SharePolicy.name(String(path.split(separator: "/").last ?? ""))
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let link = try JSONDecoder().decode(String.self, from: await request(repo("upload-link"), query: [.init(name: "p", value: SeafilePolicy.path(parent))]))
        var url = URLComponents(url: try SeafilePolicy.transferURL(link, base: connection.address), resolvingAgainstBaseURL: false)!
        url.queryItems = (url.queryItems ?? []).filter { $0.name != "ret-json" } + [.init(name: "ret-json", value: "1")]
        let boundary = "AsterOS" + UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("asteros-multipart-" + UUID().uuidString)
        FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: body) }
        let output = try FileHandle(forWritingTo: body)
        do {
            for (key, value) in [("parent_dir", try SeafilePolicy.path(parent)), ("replace", "0")] {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            try handle.seek(toOffset: 0)
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: chunk); activity?(); await Task.yield() }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8)); try output.close()
        } catch { try? output.close(); throw error }
        var request = URLRequest(url: url.url!); request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = SeafileSessionDelegate(progress: progress)
        let (data, response) = try await session.upload(for: request, fromFile: body, delegate: delegate)
        try check(response)
        struct Uploaded: Decodable { let name: String; let size: UInt64 }
        let result = try JSONDecoder().decode([Uploaded].self, from: data)
        guard result.count == 1, result[0].name == name else { throw AppError.message("A file with that name already exists. Seafile kept both copies; backup was not marked complete.") }
    }
    func rename(_ source: String, to destination: String) async throws {
        let parent = source.split(separator: "/").dropLast().joined(separator: "/")
        guard parent == destination.split(separator: "/").dropLast().joined(separator: "/") else { throw AppError.message("Only renaming within a folder is supported.") }
        let name = try SharePolicy.name(String(destination.split(separator: "/").last ?? ""))
        let before = try await list(parent)
        guard !before.contains(where: { $0.name == name }), let old = before.first(where: { $0.name == source.split(separator: "/").last.map(String.init) }) else { throw AppError.message("The destination already exists or the upload is unavailable. Existing files were preserved.") }
        _ = try await request(repo("file"), query: [.init(name: "p", value: SeafilePolicy.path(source)), .init(name: "reloaddir", value: "true")], form: ["operation": "rename", "newname": name])
        guard try await list(parent).contains(where: { $0.name == name && $0.id == old.id }) else { throw AppError.message("Seafile could not confirm the final filename. Backup was not marked complete.") }
    }
}

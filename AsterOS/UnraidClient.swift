import Foundation

// API keys must never follow redirects to an authentication gateway or other host.
final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
protocol ServerAPI {
    func overview() async throws -> Overview
    func containers() async throws -> [Container]
    func metrics() async throws -> Metrics
    func perform(_ action: ContainerAction, id: String) async throws
    func removeContainer(id: String) async throws
}
final class UnraidClient: ServerAPI {
    let profile: ServerProfile
    private let key: String
    init(profile: ServerProfile, key: String) { self.profile = profile; self.key = key }
    func query<T: Decodable>(_ document: String, variables: [String: String] = [:]) async throws -> T {
        _ = try AddressPolicy.validate(profile.address.absoluteString)
        var request = URLRequest(url: AddressPolicy.endpoint(profile.address))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": document, "variables": variables])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.proxyConfigurations = try await TailnetStore.shared.prepare(for: profile.address.host)
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            let e = error as NSError
            if e.domain == NSURLErrorDomain && [-1200, -1201, -1202, -1203, -1204].contains(e.code) {
                throw AppError.message(ConnectionRecovery.message(error))
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw AppError.message("The server returned an invalid response.") }
        if (300...399).contains(http.statusCode) {
            throw AppError.message(Self.redirectMessage(response: http))
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AppError.message("Access denied. Check the API key and its permissions. A proxy login may also be blocking API access.") }
        guard (200...299).contains(http.statusCode) else { throw AppError.message("Server returned HTTP \(http.statusCode). Check the address and proxy configuration. API redirects are blocked to protect your key.") }
        guard http.mimeType?.contains("json") == true else { throw AppError.message("This address returned a web page instead of the API. Check for a proxy sign-in page or an incorrect server address.") }
        let payload = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let errors = payload.errors, !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: "\n").replacingOccurrences(of: key, with: "[redacted]")
            throw AppError.message(String(message.prefix(800)))
        }
        guard let result = payload.data else { throw AppError.message("The API returned no data.") }
        return result
    }
    static func redirectMessage(response: HTTPURLResponse) -> String {
        let destination = response.value(forHTTPHeaderField: "Location")
            .flatMap { URL(string: $0, relativeTo: response.url)?.absoluteURL.host }
        let hint = destination.map { " to \($0)" } ?? ""
        return "The server redirected the API request\(hint) (HTTP \(response.statusCode)). A website login such as Cloudflare Access or Organizr, or an incorrect server URL, may be blocking it. Use a directly reachable HTTPS local/VPN address or a separately authenticated app endpoint. Your API key was not forwarded to the redirect."
    }
    func overview() async throws -> Overview { try await query(Self.overviewQuery) }
    func containers() async throws -> [Container] {
        let data: DockerData = try await query(Self.containersQuery)
        return data.docker.containers
    }
    func metrics() async throws -> Metrics {
        let data: MetricsData = try await query(Self.metricsQuery)
        return data.metrics
    }
    func perform(_ action: ContainerAction, id: String) async throws {
        let _: ActionData = try await query("mutation ContainerAction($id: PrefixedID!) { docker { \(action.rawValue)(id: $id) { id } } }", variables: ["id": id])
    }
    func removeContainer(id: String) async throws {
        let result: ContainerRemovalData = try await query(Self.removeContainerMutation, variables: ["id": id])
        guard result.docker.removeContainer else { throw AppError.message("Unraid did not confirm removal. Refresh the app list before trying again.") }
    }
    static let removeContainerMutation = "mutation RemoveContainer($id: PrefixedID!) { docker { removeContainer(id: $id, withImage: false) } }"
    static let overviewQuery = "query Overview { info { os { hostname release } cpu { brand cores } } array { state capacity { kilobytes { free used total } } disks { id name temp status } } }"
    static let containersQuery = "query Containers { docker { containers { id names state status iconUrl webUiUrl labels ports { ip privatePort publicPort type } hostConfig { networkMode } networkSettings } } }"
    static let metricsQuery = "query Metrics { metrics { cpu { percentTotal } memory { percentTotal } } }"
}

struct ContainerRemovalData: Decodable {
    struct Result: Decodable { let removeContainer: Bool }
    let docker: Result
}

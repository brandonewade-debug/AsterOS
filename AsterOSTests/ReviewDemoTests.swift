import XCTest
import SwiftUI
@testable import AsterOS

private final class ReviewAPI: ServerAPI {
    var cancelledStage: String?
    func overview() async throws -> Overview {
        if cancelledStage == "overview" { throw URLError(.cancelled) }
        return .demo
    }
    func containers() async throws -> [Container] {
        if cancelledStage == "apps" { throw CancellationError() }
        return [Container(id: "sample", names: ["Sample"], state: "RUNNING", status: "Up")]
    }
    func metrics() async throws -> Metrics {
        if cancelledStage == "metrics" { throw URLError(.cancelled) }
        return .demo
    }
    func perform(_ action: ContainerAction, id: String) async throws { XCTFail("Demo must not send mutations") }
    func removeContainer(id: String) async throws { XCTFail("Demo must not send removals") }
}
final class ReviewDemoTests: XCTestCase {
    @MainActor func testDemoPreservesSavedServerAndNeverCreatesClient() async throws {
        let suite = "demo-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerProfile(name: "Real", address: URL(string: "https://example.invalid")!, connection: .custom)
        let original = try JSONEncoder().encode([server])
        defaults.set(original, forKey: "serverProfiles")
        defaults.set(server.id.uuidString, forKey: "selectedServer")
        var calls = 0
        let store = AppStore(defaults: defaults, client: { _ in calls += 1; return ReviewAPI() })
        store.showDemo(); store.showDemo()
        XCTAssertNil(store.selected); XCTAssertTrue(store.demo)
        await store.refresh()
        await store.perform(.stop, container: Container(id: "sample", names: ["Sample"], state: "RUNNING", status: "Up"))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(defaults.data(forKey: "serverProfiles"), original)
        XCTAssertEqual(AppStore(defaults: defaults).selectedID, server.id)
        store.exitDemo()
        XCTAssertEqual(store.selectedID, server.id)
        XCTAssertFalse(store.demo)
    }
    @MainActor func testCancellationDoesNotSurfaceFailureOrDiscardCachedReadings() async throws {
        for phase in ["overview", "apps", "metrics"] {
            let suite = "cancel-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let server = ServerProfile(name: "Fixture", address: URL(string: "https://example.invalid")!, connection: .custom)
            defaults.set(try JSONEncoder().encode([server]), forKey: "serverProfiles")
            let api = ReviewAPI()
            let store = AppStore(defaults: defaults, client: { _ in api })
            await store.refresh()
            api.cancelledStage = phase
            await store.refresh()
            XCTAssertNil(store.error); XCTAssertNil(store.dockerError); XCTAssertNil(store.metricsError)
            XCTAssertNotNil(store.metrics); XCTAssertEqual(store.containers.count, 1)
            XCTAssertFalse(store.loading); XCTAssertNil(store.connectionStage); XCTAssertNil(store.stageStarted)
        }
    }
    @MainActor func testSampleContainerChangesAreIsolatedAndResettable() {
        let sample = DemoWorkspace()
        var app = DemoWorkspace.catalog[2]; app.port = "9090"
        sample.save(app)
        XCTAssertEqual(sample.apps.count, 3)
        XCTAssertEqual(sample.apps.last?.port, "9090")
        sample.folderMembers.insert(app.id); sample.remove(app.id)
        XCTAssertEqual(sample.apps.count, 2); XCTAssertFalse(sample.folderMembers.contains(app.id))
        sample.backupCount = 3
        XCTAssertEqual(sample.backupCount, 3)
        sample.reset()
        XCTAssertEqual(sample.backupCount, 0)
        XCTAssertEqual(sample.apps, Array(DemoWorkspace.catalog.prefix(2)))
    }
    @MainActor func testDashboardDemoIncludesConsistentOfflineMetrics() {
        let telemetry = DashboardTelemetry(); telemetry.loadDemo()
        XCTAssertEqual(telemetry.live?.metrics.network?.first?.name, "eth0")
        XCTAssertEqual(telemetry.gpus.count, 1)
        XCTAssertEqual(telemetry.packages?.temperature, 42)
        let memory = telemetry.live?.metrics.memory
        XCTAssertEqual((memory?.used?.value ?? 0) / (memory?.total?.value ?? 1) * 100, 38, accuracy: 0.01)
    }

    @MainActor func testDemoScreensRenderForPhone() async throws {
        let sample = DemoWorkspace()
        let screens: [(String, AnyView)] = [
            ("apps", AnyView(DemoAppsView())),
            ("photos", AnyView(DemoPhotosView())),
            ("files", AnyView(DemoFilesView())),
            ("editor", AnyView(NavigationStack { DemoAppEditor(app: DemoWorkspace.catalog[0], installing: true) }))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, view) in screens {
            let controller = UIHostingController(rootView: view.environmentObject(sample).preferredColorScheme(.dark).tint(.mint))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = controller; window.makeKeyAndVisible()
            controller.view.frame = window.bounds; window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/asteros-demo-\(name).png"))
            window.isHidden = true; window.rootViewController = nil
        }
    }
}

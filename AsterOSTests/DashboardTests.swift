import XCTest
import SwiftUI
@testable import AsterOS

final class DashboardTests: XCTestCase {
    func testGPUPluginConfigurationIsParsedAsDataAndRejectsUnsafeIdentifiers() throws {
        let html = #"<script>$(gpustat_statusm({"gpu":{"vendor":"nvidia","id":"01:00.0","guid":"GPU-abcd-1234","model":"Example"}}));</script>"#
        let data = try GPUStatisticsPolicy.configuration(html: html)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(object["01:00.0"]?["vendor"] as? String, "nvidia")
        XCTAssertNil(object["01:00.0"]?["model"])
        XCTAssertThrowsError(try GPUStatisticsPolicy.configuration(html: html.replacingOccurrences(of: "GPU-abcd-1234", with: "GPU-abc;bad")))
        XCTAssertThrowsError(try GPUStatisticsPolicy.configuration(html: "<html>Login</html>"))
    }
    func testGPUActualPluginUnitsAndMissingValues() throws {
        let data = Data(#"{"01:00.0":{"name":"Quadro P4000","util":"0%","temp":"100F","power":"9W","memutil":"0%","encutil":"N/A","decutil":"12%","vfio":false},"02:00.0":{"name":"Other GPU","util":"N/A","temp":"N/A","power":"N/A","vfio":true}}"#.utf8)
        let gpus = try GPUStatisticsPolicy.decode(data)
        XCTAssertEqual(gpus[0].temperature!, 37.777777, accuracy: 0.001)
        XCTAssertEqual(gpus[0].utilization, 0)
        XCTAssertEqual(gpus[0].power, 9)
        XCTAssertNil(gpus[0].encoder)
        XCTAssertEqual(gpus[0].decoder, 12)
        XCTAssertNil(gpus[1].utilization)
        XCTAssertTrue(gpus[1].unavailable)
        XCTAssertNil(GPUStatisticsPolicy.number(true))
        XCTAssertNil(GPUStatisticsPolicy.percent("101%"))
    }
    func testNetworkPrefersOneInterfaceWithoutDoubleCountingBridges() throws {
        let data = Data(#"{"metrics":{"cpu":{"percentTotal":8},"memory":{"total":"34359738368","used":4294967296,"percentTotal":12.5},"network":[{"name":"lo","operstate":"up","rxSec":9999,"txSec":9999},{"name":"eth0","operstate":"up","rxSec":200,"txSec":300},{"name":"br0","operstate":"up","rxSec":200,"txSec":300}]}}"#.utf8)
        let live = try JSONDecoder().decode(DashboardLive.self, from: data)
        XCTAssertEqual(live.metrics.memory?.total?.value, 34359738368)
        XCTAssertEqual(DashboardNetwork.preferred(live.metrics.network!)?.name, "br0")
        XCTAssertEqual(DashboardNetwork.preferred(live.metrics.network!)?.rxSec, 200)
        XCTAssertEqual(DashboardDisplay.percentage(nil), "—")
        XCTAssertEqual(DashboardDisplay.rate(-1), "—")
        XCTAssertEqual(DashboardDisplay.percentage(.nan), "—")
        XCTAssertEqual(DashboardDisplay.percentage(0), "0%")
    }
    func testCPUTemperatureUsesCPUSensorsAndConvertsUnits() throws {
        let data = Data(#"{"metrics":{"temperature":{"sensors":[{"id":"cpu","name":"Package","type":"CPU_PACKAGE","current":{"value":95,"unit":"FAHRENHEIT"}},{"id":"disk","name":"NVMe","type":"NVME","current":{"value":70,"unit":"CELSIUS"}}]}}}"#.utf8)
        let readings = try JSONDecoder().decode(DashboardTemperature.self, from: data)
        XCTAssertEqual(readings.cpuCelsius, 35)
        XCTAssertEqual(DashboardDisplay.temperature(readings.cpuCelsius, fahrenheit: true), "95°")
    }
    func testStorageCountsAndInvalidTemperatureAreHandled() throws {
        let data = Data(#"{"array":{"caches":[{"id":"cache","name":"cache","fsType":"btrfs","status":"DISK_OK","fsSize":"1000","fsFree":750,"fsUsed":"250"}],"boot":null,"disks":[]}}"#.utf8)
        let storage = try JSONDecoder().decode(DashboardStorage.self, from: data)
        XCTAssertEqual(storage.array.caches[0].fraction, 0.25)
        XCTAssertEqual(storage.array.caches[0].fsFree?.value, 750)
        XCTAssertEqual(DashboardDisplay.temperature(1e300, fahrenheit: true), "—")
        XCTAssertEqual(DashboardDisplay.memory(34_359_738_368), "32 GB")
    }
    @MainActor func testDashboardRendersPhonePreview() async throws {
        let suite = "dashboard-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults); store.showDemo()
        let telemetry = DashboardTelemetry()
        telemetry.live = try JSONDecoder().decode(DashboardLive.self, from: Data(#"{"metrics":{"cpu":{"percentTotal":14},"memory":{"total":"34359738368","used":"13056700579","percentTotal":38},"network":[{"name":"eth0","operstate":"up","rxSec":5300000,"txSec":260000,"utilizationPercent":2}]}}"#.utf8))
        telemetry.temperatures = try JSONDecoder().decode(DashboardTemperature.self, from: Data(#"{"metrics":{"temperature":{"sensors":[{"id":"cpu","name":"Package","type":"CPU_PACKAGE","current":{"value":44,"unit":"CELSIUS"}}]}}}"#.utf8))
        telemetry.gpus = [DashboardGPU(id: "sample", name: "Sample GPU", utilization: 28, temperature: 42, power: 21, memory: 13, encoder: 10, decoder: 0, unavailable: false)]
        let content = DashboardView(telemetry: telemetry).environmentObject(store).environmentObject(TailnetStore.shared).preferredColorScheme(.dark)
        let controller = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        XCTAssertEqual(image.size.width, 402)
        let url = URL(fileURLWithPath: "/tmp/asteros-dashboard-preview.png")
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}

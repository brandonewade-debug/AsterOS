import XCTest
@testable import AsterOS

final class ContainerHealthTests: XCTestCase {
    private func item(_ state: String, _ status: String) -> Container {
        Container(id: UUID().uuidString, names: ["/Fixture"], state: state, status: status)
    }
    func testUnhealthyIsNeverMistakenForHealthy() {
        let container = item("RUNNING", "Up 4 hours (unhealthy)")
        XCTAssertEqual(container.reportedHealth, .unhealthy)
        XCTAssertTrue(container.needsAttention)
    }
    func testNoHealthCheckDoesNotClaimHealthy() {
        let summary = ContainerHealthSummary(containers: [item("running", "Up 2 hours")])
        XCTAssertEqual(summary.healthy, 0)
        XCTAssertEqual(summary.unreported, 1)
        XCTAssertEqual(summary.title, "All containers running")
        XCTAssertTrue(summary.attention.isEmpty)
    }
    func testOfflineStatesAndHealthStartingAppearInAttention() {
        let values = ["EXITED", "PAUSED", "RESTARTING", "CREATED", "DEAD", "REMOVING", ""].map { item($0, "Stopped") }
        let summary = ContainerHealthSummary(containers: values + [item("RUNNING", "Up 3 seconds (health: starting)")])
        XCTAssertEqual(summary.attention.count, 8)
        XCTAssertEqual(summary.online, 1)
    }
    func testAllHealthyRequiresEveryContainerRunningAndHealthy() {
        let healthy = item("RUNNING", "Up 3 hours (healthy)")
        XCTAssertEqual(ContainerHealthSummary(containers: [healthy]).title, "All containers running and healthy")
        XCTAssertTrue(item("EXITED", "Previously (healthy)").needsAttention)
        XCTAssertEqual(ContainerHealthSummary(containers: []).title, "No container status yet")
    }
}

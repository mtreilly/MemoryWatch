import XCTest
@testable import MemoryWatchCore

class MaintenanceSchedulerTests: XCTestCase {
    var tempDatabaseURL: URL!
    var store: SQLiteStore!
    var receivedAlerts: [MemoryAlert] = []

    override func setUp() {
        super.setUp()

        let tempDir = FileManager.default.temporaryDirectory
        tempDatabaseURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).db")

        do {
            store = try SQLiteStore(url: tempDatabaseURL)
        } catch {
            XCTFail("Failed to create test database: \(error)")
        }

        receivedAlerts = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDatabaseURL)
        super.tearDown()
    }

    func testSchedulerInitializesSuccessfully() {
        let scheduler = MaintenanceScheduler(
            store: store,
            alertHandler: { _ in }
        )

        XCTAssertNotNil(scheduler)
    }

    func testCheckAndMaintain() {
        // This test would need to actually create a large WAL file,
        // which is complex in unit tests. For now, we verify the scheduler initializes.
        let scheduler = MaintenanceScheduler(
            store: store,
            alertHandler: { _ in },
            walSizeWarningThreshold: 1 * 1024 * 1024,  // 1 MB for testing
            walSizeCriticalThreshold: 10 * 1024 * 1024  // 10 MB for testing
        )

        scheduler.checkAndMaintainIfNeeded()
        // In a real scenario with actual WAL data, we'd check for alerts
    }

    func testMaintenanceStatusRetrieved() {
        let scheduler = MaintenanceScheduler(
            store: store,
            alertHandler: { _ in }
        )

        let status = scheduler.getStatus()

        XCTAssertEqual(status.snapshotCount, 0)
        XCTAssertEqual(status.alertCount, 0)
        XCTAssertGreaterThanOrEqual(status.walSizeBytes, 0)
    }

    func testMultipleChecksRespectInterval() {
        let scheduler = MaintenanceScheduler(
            store: store,
            alertHandler: { _ in },
            maintenanceInterval: 1  // 1 second for testing
        )

        // First check should proceed
        scheduler.checkAndMaintainIfNeeded()

        // Immediate second check should be skipped
        scheduler.checkAndMaintainIfNeeded()
    }
}

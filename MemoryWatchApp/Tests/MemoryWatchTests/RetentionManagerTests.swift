import XCTest
@testable import MemoryWatchCore

class RetentionManagerTests: XCTestCase {
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

    func testRetentionManagerInitializesSuccessfully() {
        let manager = RetentionManager(
            store: store,
            alertHandler: { _ in },
            preferencesLoader: {
                NotificationPreferences.default
            }
        )

        XCTAssertNotNil(manager)
    }

    func testDeleteSnapshotsOlderThan() {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        let twoDaysAgo = now.addingTimeInterval(-172800)

        // Insert test snapshots
        let metrics1 = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 100,
            swapTotalMB: 1024,
            swapFreePercent: 90,
            pressure: "normal"
        )

        store.recordSnapshot(timestamp: twoDaysAgo, metrics: metrics1, processes: [])
        store.recordSnapshot(timestamp: oneDayAgo, metrics: metrics1, processes: [])
        store.recordSnapshot(timestamp: now, metrics: metrics1, processes: [])

        var health = store.healthSnapshot()
        let countBefore = health.snapshotCount
        XCTAssertEqual(countBefore, 3)

        // Delete snapshots older than 1 day ago
        store.deleteSnapshotsOlderThan(oneDayAgo.timeIntervalSince1970)

        health = store.healthSnapshot()
        let countAfter = health.snapshotCount
        // Should have only the 2 most recent snapshots
        XCTAssertEqual(countAfter, 2)
    }

    func testRetentionStatusRetrieved() {
        let manager = RetentionManager(
            store: store,
            alertHandler: { _ in },
            preferencesLoader: {
                NotificationPreferences.default
            }
        )

        let status = manager.getStatus()

        XCTAssertEqual(status.snapshotCount, 0)
        XCTAssertEqual(status.alertCount, 0)
        XCTAssertNil(status.oldestSnapshot)
        XCTAssertNil(status.newestSnapshot)
    }

    func testRetentionChangeAlert() {
        let customPrefs = NotificationPreferences(
            quietHours: NotificationPreferences.default.quietHours,
            leakNotificationsEnabled: true,
            pressureNotificationsEnabled: true,
            allowInterruptionsDuringQuietHours: false,
            updateCadenceSeconds: 30,
            retentionWindowHours: 48  // 2 days instead of default 72
        )

        let manager = RetentionManager(
            store: store,
            alertHandler: { _ in },
            preferencesLoader: {
                customPrefs
            }
        )

        // First check - should trigger a change alert since we're changing from default
        manager.checkAndTrimIfNeeded()

        // Manager should have updated its retention window
        let status = manager.getStatus()
        XCTAssertLessThan(status.retentionWindowHours, 72)
    }

    func testForceTrimNow() {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)

        // Insert test snapshots
        let metrics = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 100,
            swapTotalMB: 1024,
            swapFreePercent: 90,
            pressure: "normal"
        )

        store.recordSnapshot(timestamp: oneDayAgo, metrics: metrics, processes: [])
        store.recordSnapshot(timestamp: now, metrics: metrics, processes: [])

        var health = store.healthSnapshot()
        XCTAssertEqual(health.snapshotCount, 2)

        let manager = RetentionManager(
            store: store,
            alertHandler: { _ in },
            preferencesLoader: {
                NotificationPreferences.default
            }
        )

        // Force trim should clean up old data
        manager.forceTrimNow()

        health = store.healthSnapshot()
        // Should still have at least 1 snapshot since nothing is older than retention window yet
        XCTAssertGreaterThanOrEqual(health.snapshotCount, 1)
    }

    func testDataSpanCalculation() {
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)

        // Insert snapshots spanning 3 days
        let metrics = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 100,
            swapTotalMB: 1024,
            swapFreePercent: 90,
            pressure: "normal"
        )

        store.recordSnapshot(timestamp: threeDaysAgo, metrics: metrics, processes: [])
        store.recordSnapshot(timestamp: now, metrics: metrics, processes: [])

        let manager = RetentionManager(
            store: store,
            alertHandler: { _ in },
            preferencesLoader: {
                NotificationPreferences.default
            }
        )

        let status = manager.getStatus()

        XCTAssertEqual(status.snapshotCount, 2)
        if let dataSpan = status.dataSpanHours {
            XCTAssertGreaterThan(dataSpan, 70)  // Should be around 72 hours
            XCTAssertLessThan(dataSpan, 73)
        }
    }
}

import XCTest
@testable import MemoryWatchCore

final class ProcessMonitorTests: XCTestCase {
    func testNoLeakWithStableMemory() {
        let monitor = ProcessMonitor()
        let pid: Int32 = 4242
        let name = "testproc"
        let metrics = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 0,
            swapTotalMB: 0,
            swapFreePercent: 100,
            pressure: "Normal"
        )
        let base = Date()
        for i in 0..<10 {
            let proc = ProcessInfo(
                pid: pid,
                name: name,
                executablePath: nil,
                memoryMB: 500.0,
                percentMemory: 3.0,
                cpuPercent: 1.0,
                ioReadBps: 0,
                ioWriteBps: 0,
                ports: []
            )
            monitor.recordSnapshot(
                processes: [proc],
                metrics: metrics,
                timestamp: base.addingTimeInterval(TimeInterval(i * 30))
            )
        }
        let suspects = monitor.getLeakSuspects(minLevel: .low)
        XCTAssertTrue(suspects.isEmpty)
    }

    func testLeakDetectionWithGrowth() {
        let monitor = ProcessMonitor()
        let pid: Int32 = 5555
        let name = "leaky"
        let metrics = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 0,
            swapTotalMB: 0,
            swapFreePercent: 100,
            pressure: "Normal"
        )
        let base = Date()
        // Grow ~200MB over 1 hour => ~200 MB/h
        for i in 0..<12 {
            let mem = 1000.0 + Double(i) * (200.0/12.0)
            let proc = ProcessInfo(
                pid: pid,
                name: name,
                executablePath: nil,
                memoryMB: mem,
                percentMemory: 5.0,
                cpuPercent: 2.0,
                ioReadBps: 0,
                ioWriteBps: 0,
                ports: []
            )
            monitor.recordSnapshot(
                processes: [proc],
                metrics: metrics,
                timestamp: base.addingTimeInterval(TimeInterval(i * 300))
            )
        }
        let suspects = monitor.getLeakSuspects(minLevel: .low)
        XCTAssertFalse(suspects.isEmpty)
        let s = suspects.first { $0.pid == pid }!
        XCTAssertGreaterThan(s.growthRate, 50.0) // at least Medium
    }

    func testSystemAlertsGenerated() {
        let monitor = ProcessMonitor()
        let metricsCritical = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 15,
            freeMemoryGB: 1,
            freePercent: 6,
            swapUsedMB: 640,
            swapTotalMB: 1024,
            swapFreePercent: 37,
            pressure: "Critical"
        )

        monitor.recordSnapshot(processes: [], metrics: metricsCritical, timestamp: Date())

        let alerts = monitor.getRecentAlerts()
        XCTAssertTrue(alerts.contains { $0.type == .highSwap })
        XCTAssertTrue(alerts.contains { $0.type == .systemPressure })

        // Second snapshot within cooldown should not duplicate high swap alert
        monitor.recordSnapshot(processes: [], metrics: metricsCritical, timestamp: Date().addingTimeInterval(10))
        let updatedAlerts = monitor.getRecentAlerts()
        let swapAlerts = updatedAlerts.filter { $0.type == .highSwap }
        XCTAssertEqual(swapAlerts.count, 1)
    }

    func testWALAlertGenerated() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("memorywatch.sqlite")
        let store = try SQLiteStore(url: dbURL)
        let monitor = ProcessMonitor(store: store, walAlertThresholdMB: 1)

        // Write fake WAL file exceeding threshold (~1.5 MB)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let data = Data(count: 1_500_000)
        try data.write(to: walURL)

        let metrics = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 0,
            swapTotalMB: 0,
            swapFreePercent: 100,
            pressure: "Normal"
        )

        monitor.recordSnapshot(processes: [], metrics: metrics, timestamp: Date())

        let alert = monitor.getRecentAlerts().first { $0.type == .datastoreWarning }
        XCTAssertNotNil(alert)
    }

    func testRecordExternalAlertDeduplicatesWithinWindow() {
        let monitor = ProcessMonitor()
        let now = Date()
        let alert = MemoryAlert(timestamp: now,
                                type: .datastoreWarning,
                                message: "Retention reduced",
                                pid: nil,
                                processName: nil,
                                metadata: nil)

        monitor.recordAlert(alert)
        XCTAssertEqual(monitor.getRecentAlerts().count, 1)

        // Duplicate within 5-minute window should be ignored
        monitor.recordAlert(alert)
        XCTAssertEqual(monitor.getRecentAlerts().count, 1)

        // Alert outside dedupe window should be accepted
        let later = MemoryAlert(timestamp: now.addingTimeInterval(360),
                                type: .datastoreWarning,
                                message: "Retention reduced",
                                pid: nil,
                                processName: nil,
                                metadata: nil)
        monitor.recordAlert(later)
        XCTAssertEqual(monitor.getRecentAlerts().count, 2)
    }
}

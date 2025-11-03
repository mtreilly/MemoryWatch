import XCTest
@testable import MemoryWatchCore

@MainActor
final class MenuBarStateTests: XCTestCase {
    func testRefreshPopulatesSnapshot() {
        let metrics = SystemMetrics(
            totalMemoryGB: 16,
            usedMemoryGB: 8,
            freeMemoryGB: 8,
            freePercent: 50,
            swapUsedMB: 128,
            swapTotalMB: 512,
            swapFreePercent: 75,
            pressure: "Normal"
        )

        let process = ProcessInfo(
            pid: 7777,
            name: "Electron Helper",
            executablePath: "/Applications/Electron.app/Contents/MacOS/Electron Helper",
            memoryMB: 600,
            percentMemory: 4.5,
            cpuPercent: 12,
            ioReadBps: 0,
            ioWriteBps: 0,
            ports: []
        )

        let historySamples = [
            SnapshotHistoryPoint(
                timestamp: Date(timeIntervalSince1970: 100),
                usedMemoryGB: 8.0,
                swapUsedMB: 120,
                ssdWearMB: 0,
                topProcess: process
            ),
            SnapshotHistoryPoint(
                timestamp: Date(timeIntervalSince1970: 200),
                usedMemoryGB: 8.5,
                swapUsedMB: 150,
                ssdWearMB: 30,
                topProcess: process
            )
        ]

        let preferences = NotificationPreferences(
            quietHours: NotificationPreferences.QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60, timezoneIdentifier: TimeZone.current.identifier),
            leakNotificationsEnabled: true,
            pressureNotificationsEnabled: true,
            allowInterruptionsDuringQuietHours: false
        )

        let state = MenuBarState(
            metricsProvider: { metrics },
            processProvider: { [process] },
            dateProvider: { Date(timeIntervalSince1970: 123) },
            preferencesLoader: { preferences },
            historyLoader: { historySamples }
        )

        let monitor = ProcessMonitor()
        let base = Date()
        for i in 0..<10 {
            let mem = 500.0 + Double(i) * 35.0
            let proc = ProcessInfo(
                pid: process.pid,
                name: process.name,
                executablePath: process.executablePath,
                memoryMB: mem,
                percentMemory: process.percentMemory,
                cpuPercent: process.cpuPercent,
                ioReadBps: process.ioReadBps,
                ioWriteBps: process.ioWriteBps,
                ports: process.ports
            )
            monitor.recordSnapshot(processes: [proc], metrics: metrics, timestamp: base.addingTimeInterval(Double(i) * 300))
        }

        state.refresh(processMonitor: monitor)

        let historyExpectation = expectation(description: "history points populated")
        let preferencesExpectation = expectation(description: "preferences loaded")
        Task { @MainActor in
            while state.historyPoints.count < historySamples.count {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            historyExpectation.fulfill()
        }
        Task { @MainActor in
            while state.snapshot.notificationPreferences != preferences {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            preferencesExpectation.fulfill()
        }
        wait(for: [historyExpectation, preferencesExpectation], timeout: 1.0)

        let snapshot = state.snapshot
        XCTAssertEqual(snapshot.metrics.totalMemoryGB, 16)
        XCTAssertEqual(snapshot.topProcess?.pid, process.pid)
        XCTAssertNotNil(snapshot.topLeakSuspect)
        XCTAssertFalse(snapshot.diagnosticHints.isEmpty)
        XCTAssertTrue(snapshot.diagnosticHints.contains { $0.artifactPath != nil })
        XCTAssertEqual(state.historyPoints.count, historySamples.count)
        XCTAssertEqual(state.historyPoints.last?.topProcess?.pid, process.pid)
        XCTAssertEqual(state.historyPoints.last?.ssdWearMB, 30)
        XCTAssertEqual(snapshot.notificationPreferences, preferences)
        XCTAssertEqual(snapshot.systemAlerts.count, 0)
        XCTAssertEqual(snapshot.isQuietHours, preferences.isQuietHours(now: snapshot.timestamp))
    }
}

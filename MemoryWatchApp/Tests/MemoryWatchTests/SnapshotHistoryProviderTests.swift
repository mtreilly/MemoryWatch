import XCTest
@testable import MemoryWatchCore

final class SnapshotHistoryProviderTests: XCTestCase {
    func testLoadHistoryComputesCumulativeWearAndTopProcess() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("memorywatch.sqlite")

        let store = try SQLiteStore(url: dbURL)

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let metrics = [
            SystemMetrics(totalMemoryGB: 16, usedMemoryGB: 6, freeMemoryGB: 10, freePercent: 60, swapUsedMB: 100, swapTotalMB: 512, swapFreePercent: 80, pressure: "Normal"),
            SystemMetrics(totalMemoryGB: 16, usedMemoryGB: 7, freeMemoryGB: 9, freePercent: 56, swapUsedMB: 200, swapTotalMB: 512, swapFreePercent: 70, pressure: "Warning"),
            SystemMetrics(totalMemoryGB: 16, usedMemoryGB: 8, freeMemoryGB: 8, freePercent: 52, swapUsedMB: 150, swapTotalMB: 512, swapFreePercent: 60, pressure: "Warning")
        ]

        for (index, metric) in metrics.enumerated() {
            let timestamp = baseDate.addingTimeInterval(Double(index) * 600)
            let snapshot = ProcessSnapshot(
                pid: 999,
                name: "TestProcess",
                executablePath: "/tmp/testprocess",
                memoryMB: 500 + Double(index) * 25,
                percentMemory: 3.2,
                cpuPercent: 12,
                ioReadBps: 0,
                ioWriteBps: 0,
                rank: 1,
                timestamp: timestamp
            )
            store.recordSnapshot(timestamp: timestamp, metrics: metric, processes: [snapshot])
        }

        let directPoints = store.fetchRecentSnapshotHistory(limit: 10)
        XCTAssertEqual(directPoints.count, 3, "SQLite store should return three persisted snapshots")

        let provider = SnapshotHistoryProvider(store: store, limit: 10, minRefreshInterval: 60)
        let points = await provider.loadHistory()

        XCTAssertEqual(points.count, 3, "Expected three history points in ascending order")
        guard points.count == 3 else { return }
        XCTAssertEqual(points[0].ssdWearMB, 0, accuracy: 0.01)
        XCTAssertEqual(points[1].ssdWearMB, 100, accuracy: 0.01)
        XCTAssertEqual(points[2].ssdWearMB, 100, accuracy: 0.01)
        XCTAssertEqual(points[1].topProcess?.pid, 999)
        XCTAssertEqual(points[1].topProcess?.executablePath, "/tmp/testprocess")

        // Ensure cached fetch avoids recomputation when within refresh interval
        let pointsCached = await provider.loadHistory()
        XCTAssertEqual(pointsCached.map(\.ssdWearMB), points.map(\.ssdWearMB))
    }
}

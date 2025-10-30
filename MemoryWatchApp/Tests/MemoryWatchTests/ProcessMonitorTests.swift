import XCTest
@testable import MemoryWatch

final class ProcessMonitorTests: XCTestCase {
    func testNoLeakWithStableMemory() {
        let monitor = ProcessMonitor()
        let pid: Int32 = 4242
        let name = "testproc"
        let base = Date()
        for i in 0..<10 {
            monitor.recordSnapshot(processes: [(pid, name, 500.0, 3.0)], timestamp: base.addingTimeInterval(TimeInterval(i*30)))
        }
        let suspects = monitor.getLeakSuspects(minLevel: .low)
        XCTAssertTrue(suspects.isEmpty)
    }

    func testLeakDetectionWithGrowth() {
        let monitor = ProcessMonitor()
        let pid: Int32 = 5555
        let name = "leaky"
        let base = Date()
        // Grow ~200MB over 1 hour => ~200 MB/h
        for i in 0..<12 {
            let mem = 1000.0 + Double(i) * (200.0/12.0)
            monitor.recordSnapshot(processes: [(pid, name, mem, 5.0)], timestamp: base.addingTimeInterval(TimeInterval(i*300)))
        }
        let suspects = monitor.getLeakSuspects(minLevel: .low)
        XCTAssertFalse(suspects.isEmpty)
        let s = suspects.first { $0.pid == pid }!
        XCTAssertGreaterThan(s.growthRate, 50.0) // at least Medium
    }
}


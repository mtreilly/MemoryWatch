import XCTest
@testable import MemoryWatchCore

final class LeakHeuristicsTests: XCTestCase {
    func testHighSlopeTriggersHighSuspicion() {
        let start = Date()
        var samples: [ProcessSnapshot] = []
        for index in 0..<12 {
            let timestamp = start.addingTimeInterval(Double(index) * 300) // 5 min intervals
            let snapshot = ProcessSnapshot(
                pid: 1234,
                name: "TestProcess",
                memoryMB: 500 + Double(index) * 25,
                percentMemory: 0,
                cpuPercent: 0,
                ioReadBps: 0,
                ioWriteBps: 0,
                rank: Int32(index + 1),
                timestamp: timestamp
            )
            samples.append(snapshot)
        }

        guard let evaluation = LeakHeuristics.evaluate(samples: samples[...]) else {
            XCTFail("Expected evaluation")
            return
        }

        let level = LeakHeuristics.suspicionLevel(for: evaluation)
        XCTAssertTrue(level == .high || level == .critical)
    }

    func testFlatUsageIsIgnored() {
        let start = Date()
        let samples = (0..<12).map { index -> ProcessSnapshot in
            let timestamp = start.addingTimeInterval(Double(index) * 300)
            return ProcessSnapshot(
                pid: 4321,
                name: "IdleProcess",
                memoryMB: 800,
                percentMemory: 0,
                cpuPercent: 0,
                ioReadBps: 0,
                ioWriteBps: 0,
                rank: Int32(index + 1),
                timestamp: timestamp
            )
        }

        let evaluation = LeakHeuristics.evaluate(samples: samples[...])
        XCTAssertNotNil(evaluation)
        if let evaluation {
            let level = LeakHeuristics.suspicionLevel(for: evaluation)
            XCTAssertEqual(level, .low)
            XCTAssertLessThan(evaluation.slopeMBPerHour, 1.0)
        }
    }
}

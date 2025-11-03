import Foundation

public struct SnapshotHistoryPoint: Identifiable, Sendable {
    public let timestamp: Date
    public let usedMemoryGB: Double
    public let swapUsedMB: Double
    public let ssdWearMB: Double
    public let topProcess: ProcessInfo?

    public var id: Date { timestamp }

    public init(timestamp: Date, usedMemoryGB: Double, swapUsedMB: Double, ssdWearMB: Double, topProcess: ProcessInfo?) {
        self.timestamp = timestamp
        self.usedMemoryGB = usedMemoryGB
        self.swapUsedMB = swapUsedMB
        self.ssdWearMB = ssdWearMB
        self.topProcess = topProcess
    }
}

public actor SnapshotHistoryProvider {
    private let store: SQLiteStore
    private let limit: Int
    private let minRefreshInterval: TimeInterval
    private var cache: [SnapshotHistoryPoint] = []
    private var lastFetch: Date = .distantPast

    public init(store: SQLiteStore, limit: Int = 60, minRefreshInterval: TimeInterval = 30) {
        self.store = store
        self.limit = limit
        self.minRefreshInterval = minRefreshInterval
    }

    public func loadHistory() -> [SnapshotHistoryPoint] {
        let now = Date()
        if now.timeIntervalSince(lastFetch) < minRefreshInterval, !cache.isEmpty {
            return cache
        }
        let points = store.fetchRecentSnapshotHistory(limit: limit)
        var adjusted: [SnapshotHistoryPoint] = []
        var lastSwap: Double?
        var cumulativeWear: Double = 0

        for point in points {
            if let last = lastSwap {
                let delta = point.swapUsedMB - last
                if delta > 0 {
                    cumulativeWear += delta
                }
            }
            lastSwap = point.swapUsedMB
            adjusted.append(SnapshotHistoryPoint(
                timestamp: point.timestamp,
                usedMemoryGB: point.usedMemoryGB,
                swapUsedMB: point.swapUsedMB,
                ssdWearMB: cumulativeWear,
                topProcess: point.topProcess
            ))
        }

        cache = adjusted
        lastFetch = now
        return adjusted
    }
}

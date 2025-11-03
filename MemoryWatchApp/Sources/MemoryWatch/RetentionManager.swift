import Foundation

/// Manages data retention policies and configurable cleanup schedules.
/// Respects user preferences while maintaining sensible bounds for system stability.
public class RetentionManager {
    private let store: SQLiteStore
    private let alertHandler: @Sendable (MemoryAlert) -> Void
    private let preferencesLoader: @Sendable () async -> NotificationPreferences

    // Configuration
    private let minimumRetentionHours: Double = 1          // At least 1 hour
    private let maximumRetentionHours: Double = 24 * 720  // At most 720 days
    private let defaultRetentionHours: Double = 24 * 14   // Default 14 days
    private let alertRetentionHours: Double = 24 * 30     // Alerts always kept 30 days

    // State
    private var currentRetentionHours: Double
    private var lastTrimCheck: Date = .distantPast
    private let trimCheckInterval: TimeInterval = 300     // Check every 5 minutes
    private let lock = NSLock()

    /// Initialize the retention manager
    /// - Parameters:
    ///   - store: The SQLite store to manage
    ///   - alertHandler: Closure to handle retention-related alerts
    ///   - preferencesLoader: Async closure to load current preferences
    public init(store: SQLiteStore,
                alertHandler: @escaping @Sendable (MemoryAlert) -> Void,
                preferencesLoader: @escaping @Sendable () async -> NotificationPreferences) {
        self.store = store
        self.alertHandler = alertHandler
        self.preferencesLoader = preferencesLoader
        self.currentRetentionHours = defaultRetentionHours
    }

    /// Check and trim data if retention window has changed or cleanup is due
    public func checkAndTrimIfNeeded() async {
        let now = Date()

        guard now.timeIntervalSince(lastTrimCheck) >= trimCheckInterval else {
            return
        }

        lastTrimCheck = now

        // Load current preferences
        let preferences = await preferencesLoader()
        let newRetention = Double(preferences.retentionWindowHours)

        // If retention window changed, perform immediate trim
        if abs(newRetention - currentRetentionHours) > 0.1 {
            await handleRetentionChange(from: currentRetentionHours, to: newRetention, at: now)
            currentRetentionHours = newRetention
        }

        // Perform periodic data cleanup
        await performCleanup(at: now)
    }

    /// Get current retention status
    public func getStatus() -> RetentionStatus {
        lock.lock()
        defer { lock.unlock() }

        let health = store.healthSnapshot()

        return RetentionStatus(
            retentionWindowHours: Int(currentRetentionHours),
            snapshotCount: health.snapshotCount,
            oldestSnapshot: health.oldestSnapshot,
            newestSnapshot: health.newestSnapshot,
            alertCount: health.alertCount,
            estimatedCleanupPercentage: calculateEstimatedCleanup(health)
        )
    }

    /// Force immediate trim to respect current retention window
    public func forceTrimNow() async {
        await performCleanup(at: Date())
    }

    // MARK: - Private

    private func handleRetentionChange(from oldHours: Double, to newHours: Double, at timestamp: Date) async {
        let changePercentage = ((newHours - oldHours) / oldHours) * 100

        let direction = newHours > oldHours ? "extended" : "reduced"
        let alert = MemoryAlert(
            timestamp: timestamp,
            type: .datastoreWarning,
            message: "Data retention window \(direction): from \(Int(oldHours)) to \(Int(newHours)) hours. Cleanup will adjust in next maintenance cycle.",
            pid: nil,
            processName: nil,
            metadata: [
                "component": "retention_management",
                "old_retention_hours": String(Int(oldHours)),
                "new_retention_hours": String(Int(newHours)),
                "change_percent": String(format: "%.1f", changePercentage)
            ]
        )

        alertHandler(alert)
    }

    private func performCleanup(at timestamp: Date) async {
        let snapshotCutoff = timestamp.timeIntervalSince1970 - (currentRetentionHours * 3600)
        let alertCutoff = timestamp.timeIntervalSince1970 - (alertRetentionHours * 3600)

        // Get counts before cleanup
        let healthBefore = store.healthSnapshot()
        let snapshotCountBefore = healthBefore.snapshotCount
        let alertCountBefore = healthBefore.alertCount

        // Perform cleanup
        deleteOldSnapshots(before: snapshotCutoff)
        deleteOldAlerts(before: alertCutoff)

        // Get counts after cleanup
        let healthAfter = store.healthSnapshot()
        let snapshotCountAfter = healthAfter.snapshotCount
        let alertCountAfter = healthAfter.alertCount

        let snapshotsRemoved = snapshotCountBefore - snapshotCountAfter
        let alertsRemoved = alertCountBefore - alertCountAfter

        // Only log if something was actually removed
        if snapshotsRemoved > 0 || alertsRemoved > 0 {
            fputs("[RetentionManager] Cleanup removed \(snapshotsRemoved) snapshots, \(alertsRemoved) alerts\n", stderr)
        }
    }

    private func deleteOldSnapshots(before timestamp: Double) {
        // SQLite will cascade delete related process_samples
        store.deleteSnapshotsOlderThan(timestamp)
    }

    private func deleteOldAlerts(before timestamp: Double) {
        store.deleteAlertsOlderThan(timestamp)
    }

    private func calculateEstimatedCleanup(_ health: StoreHealth) -> Double {
        guard let newest = health.newestSnapshot, let oldest = health.oldestSnapshot else {
            return 0
        }

        let totalSpan = newest.timeIntervalSince(oldest)
        let retentionSpan = currentRetentionHours * 3600

        if totalSpan > retentionSpan {
            let excessSpan = totalSpan - retentionSpan
            return (excessSpan / totalSpan) * 100
        }

        return 0
    }
}

/// Status information for retention management
public struct RetentionStatus: Sendable {
    public let retentionWindowHours: Int
    public let snapshotCount: Int
    public let oldestSnapshot: Date?
    public let newestSnapshot: Date?
    public let alertCount: Int
    public let estimatedCleanupPercentage: Double

    public var dataSpanHours: Double? {
        guard let oldest = oldestSnapshot, let newest = newestSnapshot else {
            return nil
        }
        return newest.timeIntervalSince(oldest) / 3600
    }

    public var description: String {
        let spanStr = dataSpanHours.map { String(format: "%.1f", $0) } ?? "unknown"
        return "Retention: \(retentionWindowHours)h | Data span: \(spanStr)h | Snapshots: \(snapshotCount) | Alerts: \(alertCount)"
    }
}

import Foundation

/// Manages automated database maintenance with configurable intervals and thresholds.
/// Handles periodic cleanup, WAL optimization, and alerting for maintenance events.
public class MaintenanceScheduler {
    private let store: SQLiteStore
    private let alertHandler: @Sendable (MemoryAlert) -> Void

    // Configuration
    private let maintenanceInterval: TimeInterval  // How often to check for maintenance
    private let walSizeWarningThreshold: UInt64    // WAL size that triggers a warning alert
    private let walSizeCriticalThreshold: UInt64   // WAL size that triggers a critical alert

    // State
    private var lastMaintenanceCheck: Date = .distantPast
    private var lastWalWarningAlert: Date = .distantPast
    private var lastWalCriticalAlert: Date = .distantPast
    private let walWarningDebounce: TimeInterval = 300  // Only alert once per 5 minutes
    private let walCriticalDebounce: TimeInterval = 60  // Only alert once per minute
    private var hasPerformedInitialCheck = false

    // Task management
    private var schedulerTask: Task<Void, Never>?
    private let lock = NSLock()

    /// Initialize the maintenance scheduler
    /// - Parameters:
    ///   - store: The SQLite store to maintain
    ///   - alertHandler: Closure to handle maintenance-related alerts
    ///   - maintenanceInterval: How often to check for maintenance (default: 30 minutes)
    ///   - walSizeWarningThreshold: WAL size warning threshold (default: 100 MB)
    ///   - walSizeCriticalThreshold: WAL size critical threshold (default: 500 MB)
    public init(store: SQLiteStore,
                alertHandler: @escaping @Sendable (MemoryAlert) -> Void,
                maintenanceInterval: TimeInterval = 60 * 30,
                walSizeWarningThreshold: UInt64 = 100 * 1024 * 1024,
                walSizeCriticalThreshold: UInt64 = 500 * 1024 * 1024) {
        self.store = store
        self.alertHandler = alertHandler
        self.maintenanceInterval = maintenanceInterval
        self.walSizeWarningThreshold = walSizeWarningThreshold
        self.walSizeCriticalThreshold = walSizeCriticalThreshold
    }

    /// Check if maintenance is needed and perform it if so
    public func checkAndMaintainIfNeeded() {
        let now = Date()

        guard now.timeIntervalSince(lastMaintenanceCheck) >= maintenanceInterval else {
            return
        }

        lastMaintenanceCheck = now
        if !hasPerformedInitialCheck {
            hasPerformedInitialCheck = true
            return
        }

        // Check WAL size first
        let walSize = store.currentWALSizeBytes()
        checkWALSize(walSize, at: now)

        // Perform actual maintenance
        store.performMaintenance()
    }

    /// Get current maintenance status
    public func getStatus() -> MaintenanceStatus {
        let health = store.healthSnapshot()
        let walSize = store.currentWALSizeBytes()

        return MaintenanceStatus(
            lastMaintenance: health.lastMaintenance,
            walSizeBytes: walSize,
            snapshotCount: health.snapshotCount,
            alertCount: health.alertCount,
            databaseSizeBytes: health.databaseSizeBytes,
            pageCount: health.pageCount,
            freePageCount: health.freePageCount,
            quickCheckPassed: health.quickCheckPassed
        )
    }

    // MARK: - Private

    private func checkWALSize(_ walSize: UInt64, at now: Date) {
        if walSize >= walSizeCriticalThreshold {
            // Only alert if debounce period has passed
            if now.timeIntervalSince(lastWalCriticalAlert) >= walCriticalDebounce {
                let alert = MemoryAlert(
                    timestamp: now,
                    type: .datastoreWarning,
                    message: "Database write-ahead log (WAL) is critically large: \(formatBytes(walSize)). Consider manually running diagnostics.",
                    pid: nil,
                    processName: nil,
                    metadata: [
                        "component": "database_maintenance",
                        "severity": "critical",
                        "wal_size_bytes": String(walSize),
                        "threshold_bytes": String(walSizeCriticalThreshold)
                    ]
                )
                lastWalCriticalAlert = now
                alertHandler(alert)
            }
        } else if walSize >= walSizeWarningThreshold {
            // Only alert if debounce period has passed
            if now.timeIntervalSince(lastWalWarningAlert) >= walWarningDebounce {
                let alert = MemoryAlert(
                    timestamp: now,
                    type: .datastoreWarning,
                    message: "Database write-ahead log (WAL) is growing: \(formatBytes(walSize)). Maintenance may help reduce its size.",
                    pid: nil,
                    processName: nil,
                    metadata: [
                        "component": "database_maintenance",
                        "severity": "warning",
                        "wal_size_bytes": String(walSize),
                        "threshold_bytes": String(walSizeWarningThreshold)
                    ]
                )
                lastWalWarningAlert = now
                alertHandler(alert)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Status snapshot for maintenance operations
public struct MaintenanceStatus: Sendable {
    public let lastMaintenance: Date?
    public let walSizeBytes: UInt64
    public let snapshotCount: Int
    public let alertCount: Int
    public let databaseSizeBytes: UInt64
    public let pageCount: Int
    public let freePageCount: Int
    public let quickCheckPassed: Bool

    public var databaseHealthPercent: Double {
        guard pageCount > 0 else { return 100 }
        let usedPages = Double(pageCount - freePageCount)
        let totalPages = Double(pageCount)
        return (usedPages / totalPages) * 100
    }

    public var walHealthStatus: String {
        if walSizeBytes > 500 * 1024 * 1024 {
            return "critical"
        } else if walSizeBytes > 100 * 1024 * 1024 {
            return "warning"
        } else {
            return "healthy"
        }
    }
}

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let SQLITE_CHECKPOINT_PASSIVE_MODE = Int32(SQLITE_CHECKPOINT_PASSIVE)

public struct StoreHealth {
    public let schemaVersion: Int
    public let userVersion: Int
    public let snapshotCount: Int
    public let processSampleCount: Int
    public let alertCount: Int
    public let oldestSnapshot: Date?
    public let newestSnapshot: Date?
    public let databaseSizeBytes: UInt64
    public let walSizeBytes: UInt64
    public let pageCount: Int
    public let freePageCount: Int
    public let retentionWindowHours: Double
    public let lastMaintenance: Date?
    public let quickCheckPassed: Bool
}

/// Lightweight SQLite-backed persistence for snapshots, process samples, and alerts.
/// The store keeps a single connection with prepared statements so the daemon can
/// persist state without noticeable CPU or I/O overhead.
public final class SQLiteStore {
    private static let schemaVersion = 3
    private static let retentionWindowHours: Double = 24 * 14
    private static let alertRetentionWindowHours: Double = 24 * 30
    private static let maintenanceInterval: TimeInterval = 60 * 30 // 30 minutes

    private let databaseURL: URL
    private let db: OpaquePointer
    private let insertSnapshotStmt: OpaquePointer
    private let insertProcessStmt: OpaquePointer
    private let insertAlertStmt: OpaquePointer
    private let fetchSamplesStmt: OpaquePointer
    private let lock = NSLock()
    private var lastMaintenance: Date = .distantPast

    public init(url: URL) throws {
        databaseURL = url

        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &dbPointer, flags, nil) != SQLITE_OK {
            defer { if let dbPointer { sqlite3_close(dbPointer) } }
            throw SQLiteStoreError.openDatabase(message: SQLiteStore.lastErrorMessage(dbPointer))
        }

        guard let opened = dbPointer else {
            throw SQLiteStoreError.openDatabase(message: "sqlite3_open_v2 returned nil pointer")
        }

        db = opened

        SQLiteStore.configurePragmas(db: db)
        try SQLiteStore.migrateIfNeeded(db: db)

        insertSnapshotStmt = try SQLiteStore.prepareStatement(db: db, sql: Self.snapshotInsertSQL)
        insertProcessStmt = try SQLiteStore.prepareStatement(db: db, sql: Self.processInsertSQL)
        insertAlertStmt = try SQLiteStore.prepareStatement(db: db, sql: Self.alertInsertSQL)
        fetchSamplesStmt = try SQLiteStore.prepareStatement(db: db, sql: Self.fetchSamplesSQL)
    }

    deinit {
        sqlite3_finalize(insertSnapshotStmt)
        sqlite3_finalize(insertProcessStmt)
        sqlite3_finalize(insertAlertStmt)
        sqlite3_finalize(fetchSamplesStmt)
        sqlite3_close(db)
    }

    func recordSnapshot(timestamp: Date, metrics: SystemMetrics, processes: [ProcessSnapshot]) {
        lock.lock()
        defer { lock.unlock() }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            SQLiteStore.logError(db: db, context: "BEGIN")
            return
        }

        sqlite3_bind_double(insertSnapshotStmt, 1, timestamp.timeIntervalSince1970)
        sqlite3_bind_double(insertSnapshotStmt, 2, metrics.totalMemoryGB)
        sqlite3_bind_double(insertSnapshotStmt, 3, metrics.usedMemoryGB)
        sqlite3_bind_double(insertSnapshotStmt, 4, metrics.freeMemoryGB)
        sqlite3_bind_double(insertSnapshotStmt, 5, metrics.freePercent)
        sqlite3_bind_double(insertSnapshotStmt, 6, metrics.swapUsedMB)
        sqlite3_bind_double(insertSnapshotStmt, 7, metrics.swapTotalMB)
        sqlite3_bind_double(insertSnapshotStmt, 8, metrics.swapFreePercent)
        sqlite3_bind_text(insertSnapshotStmt, 9, metrics.pressure, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(insertSnapshotStmt, 10, Int32(processes.count))

        if sqlite3_step(insertSnapshotStmt) != SQLITE_DONE {
            SQLiteStore.logError(db: db, context: "insert snapshot")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_reset(insertSnapshotStmt)
            sqlite3_clear_bindings(insertSnapshotStmt)
            return
        }

        sqlite3_reset(insertSnapshotStmt)
        sqlite3_clear_bindings(insertSnapshotStmt)

        let snapshotId = sqlite3_last_insert_rowid(db)

        if !processes.isEmpty {
            for process in processes {
                sqlite3_bind_int64(insertProcessStmt, 1, snapshotId)
                sqlite3_bind_int(insertProcessStmt, 2, process.rank ?? 0)
                sqlite3_bind_int(insertProcessStmt, 3, process.pid)
                sqlite3_bind_text(insertProcessStmt, 4, process.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(insertProcessStmt, 5, process.memoryMB)
                sqlite3_bind_double(insertProcessStmt, 6, process.percentMemory)
                sqlite3_bind_double(insertProcessStmt, 7, process.cpuPercent)
                sqlite3_bind_double(insertProcessStmt, 8, process.ioReadBps)
                sqlite3_bind_double(insertProcessStmt, 9, process.ioWriteBps)
                if let path = process.executablePath {
                    sqlite3_bind_text(insertProcessStmt, 10, path, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(insertProcessStmt, 10)
                }

                if sqlite3_step(insertProcessStmt) != SQLITE_DONE {
                    SQLiteStore.logError(db: db, context: "insert process sample")
                }

                sqlite3_reset(insertProcessStmt)
                sqlite3_clear_bindings(insertProcessStmt)
            }
        }

        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            SQLiteStore.logError(db: db, context: "COMMIT")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }

        performMaintenanceIfNeededLocked(now: timestamp)
    }

    public func insertAlert(_ alert: MemoryAlert) {
        lock.lock()
        defer { lock.unlock() }

        sqlite3_bind_double(insertAlertStmt, 1, alert.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(insertAlertStmt, 2, alert.type.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(insertAlertStmt, 3, alert.message, -1, SQLITE_TRANSIENT)

        if let pid = alert.pid {
            sqlite3_bind_int(insertAlertStmt, 4, pid)
        } else {
            sqlite3_bind_null(insertAlertStmt, 4)
        }

        if let name = alert.processName {
            sqlite3_bind_text(insertAlertStmt, 5, name, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(insertAlertStmt, 5)
        }

        if let metadata = alert.metadata,
           let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sqlite3_bind_text(insertAlertStmt, 6, jsonString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(insertAlertStmt, 6)
        }

        if sqlite3_step(insertAlertStmt) != SQLITE_DONE {
            SQLiteStore.logError(db: db, context: "insert alert")
        }

        sqlite3_reset(insertAlertStmt)
        sqlite3_clear_bindings(insertAlertStmt)
    }

    public func fetchRecentSnapshotHistory(limit: Int) -> [SnapshotHistoryPoint] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT s.timestamp,
                   s.used_memory_gb,
                   s.swap_used_mb,
                   s.swap_used_mb AS ssd_wear_mb,
                   ps.pid,
                   ps.name,
                   ps.memory_mb,
                   ps.percent_memory,
                   ps.cpu_percent,
                   ps.path
            FROM snapshots s
            LEFT JOIN process_samples ps ON ps.snapshot_id = s.id AND ps.rank = 1
            ORDER BY s.timestamp DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        var points: [SnapshotHistoryPoint] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_double(stmt, 0)
                let used = sqlite3_column_double(stmt, 1)
                let swap = sqlite3_column_double(stmt, 2)
                let wear = sqlite3_column_double(stmt, 3)
                let pidValue = sqlite3_column_int(stmt, 4)
                let processName = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
                let process: ProcessInfo?
                if let processName {
                    let mem = sqlite3_column_double(stmt, 6)
                    let pct = sqlite3_column_double(stmt, 7)
                    let cpu = sqlite3_column_double(stmt, 8)
                    let path = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) }
                    process = ProcessInfo(pid: pidValue,
                                          name: processName,
                                          executablePath: path,
                                          memoryMB: mem,
                                          percentMemory: pct,
                                          cpuPercent: cpu,
                                          ioReadBps: 0,
                                          ioWriteBps: 0,
                                          ports: [])
                } else {
                    process = nil
                }
                points.append(SnapshotHistoryPoint(
                    timestamp: Date(timeIntervalSince1970: ts),
                    usedMemoryGB: used,
                    swapUsedMB: swap,
                    ssdWearMB: wear,
                    topProcess: process
                ))
            }
        }

        sqlite3_finalize(stmt)
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    public func healthSnapshot() -> StoreHealth {
        lock.lock()
        defer { lock.unlock() }

        let userVersion = SQLiteStore.currentUserVersion(db: db)

        var snapshotCount = 0
        var processSampleCount = 0
        var alertCount = 0
        var oldestSnapshot: Date?
        var newestSnapshot: Date?

        runQuery("SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM snapshots") { stmt in
            snapshotCount = Int(sqlite3_column_int64(stmt, 0))
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                oldestSnapshot = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                newestSnapshot = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            }
        }

        runQuery("SELECT COUNT(*) FROM process_samples") { stmt in
            processSampleCount = Int(sqlite3_column_int64(stmt, 0))
        }

        runQuery("SELECT COUNT(*) FROM alerts") { stmt in
            alertCount = Int(sqlite3_column_int64(stmt, 0))
        }

        var pageCount = 0
        var freePageCount = 0

        runQuery("PRAGMA page_count") { stmt in
            pageCount = Int(sqlite3_column_int(stmt, 0))
        }

        runQuery("PRAGMA freelist_count") { stmt in
            freePageCount = Int(sqlite3_column_int(stmt, 0))
        }

        let quickCheckPassed = runQuickCheckLocked()

        let fileManager = FileManager.default
        let databaseAttributes = (try? fileManager.attributesOfItem(atPath: databaseURL.path)) ?? [:]
        let databaseSize = (databaseAttributes[.size] as? NSNumber)?.uint64Value ?? 0

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walAttributes = (try? fileManager.attributesOfItem(atPath: walURL.path)) ?? [:]
        let walSize = (walAttributes[.size] as? NSNumber)?.uint64Value ?? 0

        let metaMaintenance = getMetaValueDouble(key: "last_maintenance_ts").map { Date(timeIntervalSince1970: $0) }
        let maintenanceDate: Date?
        if let metaMaintenance {
            maintenanceDate = metaMaintenance
        } else if lastMaintenance != .distantPast {
            maintenanceDate = lastMaintenance
        } else {
            maintenanceDate = nil
        }

        return StoreHealth(
            schemaVersion: SQLiteStore.schemaVersion,
            userVersion: userVersion,
            snapshotCount: snapshotCount,
            processSampleCount: processSampleCount,
            alertCount: alertCount,
            oldestSnapshot: oldestSnapshot,
            newestSnapshot: newestSnapshot,
            databaseSizeBytes: databaseSize,
            walSizeBytes: walSize,
            pageCount: pageCount,
            freePageCount: freePageCount,
            retentionWindowHours: SQLiteStore.retentionWindowHours,
            lastMaintenance: maintenanceDate,
            quickCheckPassed: quickCheckPassed
        )
    }

    private func performMaintenanceIfNeededLocked(now: Date) {
        if lastMaintenance != .distantPast,
           now.timeIntervalSince(lastMaintenance) < SQLiteStore.maintenanceInterval {
            return
        }

        let snapshotCutoff = now.timeIntervalSince1970 - (SQLiteStore.retentionWindowHours * 3600)
        let alertCutoff = now.timeIntervalSince1970 - (SQLiteStore.alertRetentionWindowHours * 3600)

        executeDelete(sql: "DELETE FROM snapshots WHERE timestamp < ?", cutoff: snapshotCutoff)
        executeDelete(sql: "DELETE FROM alerts WHERE timestamp < ?", cutoff: alertCutoff)

        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE_MODE, nil, nil)
        sqlite3_exec(db, "PRAGMA optimize", nil, nil, nil)

        lastMaintenance = now
        setMetaValue(key: "last_maintenance_ts", double: now.timeIntervalSince1970)
    }

    private func executeDelete(sql: String, cutoff: Double) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func setMetaValue(key: String, double: Double) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            let valueString = String(format: "%.6f", double)
            sqlite3_bind_text(stmt, 2, valueString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func getMetaValueDouble(key: String) -> Double? {
        var stmt: OpaquePointer?
        var result: Double?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                let stringValue = String(cString: text)
                result = Double(stringValue)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    private func runQuery(_ sql: String, handler: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                handler(stmt!)
            }
        }
        sqlite3_finalize(stmt)
    }

    private func runQuickCheckLocked() -> Bool {
        var stmt: OpaquePointer?
        var ok = true
        if sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    let value = String(cString: ptr)
                    if value != "ok" {
                        ok = false
                        break
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        return ok
    }

    func fetchRecentSamples(pid: Int32, name: String, limit: Int) -> [ProcessSnapshot] {
        lock.lock()
        defer { lock.unlock() }

        sqlite3_bind_int(fetchSamplesStmt, 1, pid)
        sqlite3_bind_text(fetchSamplesStmt, 2, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(fetchSamplesStmt, 3, Int32(limit))

        var samples: [ProcessSnapshot] = []

        while sqlite3_step(fetchSamplesStmt) == SQLITE_ROW {
            let memoryMB = sqlite3_column_double(fetchSamplesStmt, 0)
            let percentMemory = sqlite3_column_double(fetchSamplesStmt, 1)
            let cpuPercent = sqlite3_column_double(fetchSamplesStmt, 2)
            let ioRead = sqlite3_column_double(fetchSamplesStmt, 3)
            let ioWrite = sqlite3_column_double(fetchSamplesStmt, 4)
            let rankValue = sqlite3_column_int(fetchSamplesStmt, 5)
            let timestampValue = sqlite3_column_double(fetchSamplesStmt, 6)
            let pathPtr = sqlite3_column_text(fetchSamplesStmt, 7)
            let path = pathPtr.flatMap { String(cString: $0) }

            let snapshot = ProcessSnapshot(
                pid: pid,
                name: name,
                executablePath: path,
                memoryMB: memoryMB,
                percentMemory: percentMemory,
                cpuPercent: cpuPercent,
                ioReadBps: ioRead,
                ioWriteBps: ioWrite,
                rank: rankValue,
                timestamp: Date(timeIntervalSince1970: timestampValue)
            )
            samples.append(snapshot)
        }

        sqlite3_reset(fetchSamplesStmt)
        sqlite3_clear_bindings(fetchSamplesStmt)

        return samples.reversed()
    }

    func currentWALSizeBytes() -> UInt64 {
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let attributes = (try? FileManager.default.attributesOfItem(atPath: walURL.path)) ?? [:]
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func configurePragmas(db: OpaquePointer) {
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size=67108864", nil, nil, nil)
    }

    private static func migrateIfNeeded(db: OpaquePointer) throws {
        var version = currentUserVersion(db: db)

        if version == 0 {
            try createSchema(db: db)
            setUserVersion(db: db, version: schemaVersion)
            return
        }

        if version > schemaVersion {
            // Database is from a future version – keep current value but log.
            return
        }

        while version < schemaVersion {
            switch version {
            case 1:
                try migrateFrom1To2(db: db)
            case 2:
                try migrateFrom2To3(db: db)
            default:
                throw SQLiteStoreError.unsupportedSchemaVersion(message: "Cannot migrate from schema version \(version)")
            }
            version += 1
        }

        setUserVersion(db: db, version: schemaVersion)
    }

    private static func createSchema(db: OpaquePointer) throws {
        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            total_memory_gb REAL NOT NULL,
            used_memory_gb REAL NOT NULL,
            free_memory_gb REAL NOT NULL,
            free_percent REAL NOT NULL,
            swap_used_mb REAL NOT NULL,
            swap_total_mb REAL NOT NULL,
            swap_free_percent REAL NOT NULL,
            pressure TEXT NOT NULL,
            process_count INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS process_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
            rank INTEGER NOT NULL,
            pid INTEGER NOT NULL,
            name TEXT NOT NULL,
            memory_mb REAL NOT NULL,
            percent_memory REAL NOT NULL,
            cpu_percent REAL NOT NULL,
            io_read_bps REAL NOT NULL,
            io_write_bps REAL NOT NULL,
            path TEXT,
            UNIQUE(snapshot_id, rank, pid)
        );

        CREATE TABLE IF NOT EXISTS alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            type TEXT NOT NULL,
            message TEXT NOT NULL,
            pid INTEGER,
            process_name TEXT,
            metadata TEXT
        );

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_process_samples_pid_ts
            ON process_samples(pid, snapshot_id);

        CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp
            ON snapshots(timestamp);

        CREATE INDEX IF NOT EXISTS idx_alerts_timestamp
            ON alerts(timestamp);
        """

        if sqlite3_exec(db, schemaSQL, nil, nil, nil) != SQLITE_OK {
            throw SQLiteStoreError.createSchema(message: SQLiteStore.lastErrorMessage(db))
        }
    }

    private static func migrateFrom1To2(db: OpaquePointer) throws {
        let sql = "ALTER TABLE process_samples ADD COLUMN path TEXT"
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK {
            let message = lastErrorMessage(db)
            if !message.lowercased().contains("duplicate column name") {
                throw SQLiteStoreError.migrationFailed(message: message)
            }
        }

        let metaSQL = "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
        if sqlite3_exec(db, metaSQL, nil, nil, nil) != SQLITE_OK {
            throw SQLiteStoreError.migrationFailed(message: lastErrorMessage(db))
        }
    }

    private static func migrateFrom2To3(db: OpaquePointer) throws {
        let sql = "ALTER TABLE alerts ADD COLUMN metadata TEXT"
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK {
            let message = lastErrorMessage(db)
            if !message.lowercased().contains("duplicate column name") {
                throw SQLiteStoreError.migrationFailed(message: message)
            }
        }
    }

    private static func currentUserVersion(db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                version = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        return version
    }

    private static func setUserVersion(db: OpaquePointer, version: Int) {
        sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    }

    private static func prepareStatement(db: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteStoreError.prepareStatement(message: lastErrorMessage(db))
        }
        guard let statement else {
            throw SQLiteStoreError.prepareStatement(message: "sqlite3_prepare_v2 returned nil pointer")
        }
        return statement
    }

    private static func lastErrorMessage(_ db: OpaquePointer?) -> String {
        guard let db else { return "unknown" }
        if let cString = sqlite3_errmsg(db) {
            return String(cString: cString)
        }
        return "unknown"
    }

    private static func logError(db: OpaquePointer, context: String) {
        let message = lastErrorMessage(db)
        fputs("[SQLiteStore] Error during \(context): \(message)\n", stderr)
    }

    private static let snapshotInsertSQL = """
        INSERT INTO snapshots (
            timestamp,
            total_memory_gb,
            used_memory_gb,
            free_memory_gb,
            free_percent,
            swap_used_mb,
            swap_total_mb,
            swap_free_percent,
            pressure,
            process_count
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
    """

    private static let processInsertSQL = """
        INSERT OR REPLACE INTO process_samples (
            snapshot_id,
            rank,
            pid,
            name,
            memory_mb,
            percent_memory,
            cpu_percent,
            io_read_bps,
            io_write_bps,
            path
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
    """

    private static let alertInsertSQL = """
        INSERT INTO alerts (
            timestamp,
            type,
            message,
            pid,
            process_name,
            metadata
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);
    """

    private static let fetchSamplesSQL = """
        SELECT
            ps.memory_mb,
            ps.percent_memory,
            ps.cpu_percent,
            ps.io_read_bps,
            ps.io_write_bps,
            ps.rank,
            s.timestamp,
            ps.path
        FROM process_samples ps
        JOIN snapshots s ON ps.snapshot_id = s.id
        WHERE ps.pid = ?1 AND ps.name = ?2
        ORDER BY s.timestamp DESC
        LIMIT ?3;
    """
}

public enum SQLiteStoreError: Error {
    case openDatabase(message: String)
    case createSchema(message: String)
    case prepareStatement(message: String)
    case migrationFailed(message: String)
    case unsupportedSchemaVersion(message: String)
}

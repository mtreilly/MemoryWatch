# SQLiteStore API Reference

## Overview

The `SQLiteStore` class provides a WAL-optimized SQLite interface for persisting MemoryWatch data including process snapshots, memory alerts, and system metrics. It's designed for low-latency, high-throughput data collection with efficient retention policies.

## Core Classes

### SQLiteStore

Main interface for database operations.

#### Initialization

```swift
let store = try SQLiteStore(url: databaseURL)
```

**Parameters:**
- `url: URL` - Path to SQLite database file

**Throws:**
- `StorageError` - If database initialization fails

**Features:**
- Automatic WAL (Write-Ahead Logging) mode
- Prepared statement caching for performance
- Automatic schema versioning and migrations
- Integrity check on startup

---

## Snapshot Operations

### recordSnapshot

Record a process snapshot with system metrics.

```swift
store.recordSnapshot(
    timestamp: Date(),
    metrics: systemMetrics,
    processes: [processInfo1, processInfo2]
)
```

**Parameters:**
- `timestamp: Date` - When snapshot was taken
- `metrics: SystemMetrics` - System-wide memory/swap stats
- `processes: [ProcessInfo]` - Array of process information

**Example:**
```swift
let metrics = SystemMetrics.current()
let processInfo = ProcessInfo(
    pid: 1234,
    name: "MyApp",
    executablePath: "/Applications/MyApp.app/Contents/MacOS/MyApp",
    memoryMB: 256.5,
    percentMemory: 5.2,
    cpuPercent: 15.3,
    ioReadBps: 1024000,
    ioWriteBps: 512000,
    ports: [8080, 8081]
)

store.recordSnapshot(
    timestamp: Date(),
    metrics: metrics,
    processes: [processInfo]
)
```

---

### getRecentSnapshots

Retrieve snapshots from a time range.

```swift
let snapshots = store.getRecentSnapshots(
    hoursBack: 24,
    maxCount: 1000
)
```

**Parameters:**
- `hoursBack: Int` - How many hours back to fetch
- `maxCount: Int` - Maximum snapshots to return

**Returns:** `[ProcessSnapshot]` - Array of snapshots

**Example:**
```swift
// Get last 24 hours of snapshots
let daySnapshots = store.getRecentSnapshots(hoursBack: 24)

// Get last week, limited to 2000 records
let weekSnapshots = store.getRecentSnapshots(hoursBack: 168, maxCount: 2000)

// Process snapshots
for snapshot in daySnapshots {
    print("\(snapshot.timestamp): \(snapshot.name) - \(snapshot.memoryMB)MB")
}
```

---

### deleteSnapshotsOlderThan

Delete snapshots older than specified timestamp.

```swift
store.deleteSnapshotsOlderThan(cutoffTimestamp)
```

**Parameters:**
- `cutoffTimestamp: Double` - Unix timestamp cutoff

**Example:**
```swift
// Delete snapshots older than 30 days
let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
store.deleteSnapshotsOlderThan(thirtyDaysAgo.timeIntervalSince1970)

// Or using dates directly
let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
store.deleteSnapshotsOlderThan(cutoff.timeIntervalSince1970)
```

---

## Alert Operations

### insertAlert

Record a memory alert.

```swift
let alert = MemoryAlert(
    timestamp: Date(),
    type: .memoryLeak,
    message: "Potential memory leak in MyApp",
    pid: 1234,
    processName: "MyApp",
    metadata: [
        "suspicion_score": "0.85",
        "growth_mb": "150",
        "artifact_path": "/tmp/heap_dump.json"
    ]
)

store.insertAlert(alert)
```

**Parameters:**
- `alert: MemoryAlert` - Alert to persist

**Alert Types:**
- `.memoryLeak` - Suspected memory leak
- `.highSwap` - High swap usage
- `.rapidGrowth` - Rapid memory growth detected
- `.highMemory` - Process exceeds memory threshold
- `.diagnosticHint` - Runtime diagnostic suggestion
- `.systemPressure` - System memory pressure alert
- `.datastoreWarning` - Database maintenance warning

**Metadata Best Practices:**

```swift
let alertWithMetadata = MemoryAlert(
    timestamp: Date(),
    type: .memoryLeak,
    message: "Chrome using excessive memory",
    pid: 5678,
    processName: "Google Chrome",
    metadata: [
        // Diagnostic information
        "suspicion_score": "0.92",      // 0-1 confidence
        "growth_mb_per_hour": "45.5",   // Growth rate

        // Toolchain data
        "artifact_path": "/tmp/v8_heap.json",
        "artifact_type": "V8 Heap Dump",
        "artifact_runtime": "Chromium",
        "analysis_summary": "Large detached DOM nodes",
        "suspected_leaks_count": "3",
        "leak_severities": "high,medium",

        // Remediation hints
        "recommended_action": "Restart Chrome",
        "bundle_path": "/Applications/Google Chrome.app"
    ]
)

store.insertAlert(alertWithMetadata)
```

---

### getAlerts

Retrieve alerts from a time range.

```swift
let alerts = store.getAlerts(hoursBack: 24)
```

**Parameters:**
- `hoursBack: Int` - How many hours back to fetch

**Returns:** `[MemoryAlert]` - Array of alerts

**Example:**
```swift
// Get last 24 hours of alerts
let dailyAlerts = store.getAlerts(hoursBack: 24)

// Filter by severity from metadata
let criticalAlerts = dailyAlerts.filter { alert in
    alert.metadata?["severity"] == "critical"
}

// Group by process
let alertsByProcess = Dictionary(grouping: dailyAlerts) { $0.processName }
```

---

### deleteAlertsOlderThan

Delete alerts older than specified time.

```swift
store.deleteAlertsOlderThan(cutoffTimestamp)
```

**Parameters:**
- `cutoffTimestamp: Double` - Unix timestamp cutoff

**Example:**
```swift
// Keep alerts for 90 days
let ninetyDaysAgo = Date().addingTimeInterval(-90 * 86400)
store.deleteAlertsOlderThan(ninetyDaysAgo.timeIntervalSince1970)
```

---

## Database Health Operations

### healthSnapshot

Get database health metrics.

```swift
let health = store.healthSnapshot()
```

**Returns:** `StoreHealth` with:
- `snapshotCount: Int` - Total snapshots stored
- `alertCount: Int` - Total alerts stored
- `walSizeBytes: UInt64` - Write-Ahead Log size
- `databaseSizeBytes: UInt64` - Main database file size
- `pageCount: Int` - Total database pages
- `freePageCount: Int` - Unused pages available for reuse
- `quickCheckPassed: Bool` - Last integrity check result
- `lastMaintenance: Date?` - When last maintenance ran

**Example:**
```swift
let health = store.healthSnapshot()

print("Database Summary:")
print("  Snapshots: \(health.snapshotCount)")
print("  Alerts: \(health.alertCount)")
print("  WAL Size: \(formatBytes(health.walSizeBytes))")
print("  DB Size: \(formatBytes(health.databaseSizeBytes))")
print("  Health: \(health.quickCheckPassed ? "✓" : "✗")")

// Monitor WAL growth
if health.walSizeBytes > 100_000_000 {
    print("⚠️  WAL is large, consider maintenance")
}

// Check database fragmentation
let fragmentation = Double(health.freePageCount) / Double(health.pageCount)
if fragmentation > 0.3 {
    print("⚠️  Database is \(Int(fragmentation * 100))% fragmented")
}
```

---

## Maintenance Operations

### performMaintenance

Run database maintenance including checkpoint and optimization.

```swift
store.performMaintenance()
```

**Operations:**
- Flush WAL checkpoint
- PRAGMA optimize for query planner
- PRAGMA incremental_vacuum for fragmentation
- Integrity verification

**Example:**
```swift
// Run periodic maintenance
Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
    store.performMaintenance()
    let health = store.healthSnapshot()
    print("Maintenance complete. WAL: \(formatBytes(health.walSizeBytes))")
}
```

---

### currentWALSizeBytes

Get current Write-Ahead Log size.

```swift
let walSize = store.currentWALSizeBytes()
```

**Returns:** `UInt64` - WAL file size in bytes

**Example:**
```swift
let walSize = store.currentWALSizeBytes()

switch walSize {
case 0..<50_000_000:        // < 50MB
    print("✓ WAL is healthy")
case 50_000_000..<100_000_000:  // < 100MB
    print("⚠️ WAL is growing")
default:
    print("❌ WAL is critical, needs maintenance")
    store.performMaintenance()
}
```

---

## Advanced Usage

### Integration with Leak Detection

```swift
// Record snapshot
store.recordSnapshot(timestamp: Date(), metrics: metrics, processes: processes)

// Analyze for leaks
let suspect = LeakHeuristics.analyzeProcess(pid: 1234, in: store)

// If leak suspected, capture diagnostics
if suspect.suspicionLevel == .critical {
    let toolchain = ToolchainIntegration(store: store)
    toolchain.processAlertForArtifacts(
        alert: leakAlert,
        pid: 1234,
        runtime: .chrome
    )
}
```

---

### Batch Operations

```swift
// Batch insert multiple alerts
let alerts = detectAlerts(from: snapshots)
for alert in alerts {
    store.insertAlert(alert)
}

// Efficient querying
let recentSnapshots = store.getRecentSnapshots(hoursBack: 24)
let recentAlerts = store.getAlerts(hoursBack: 24)

// Combined analysis
for alert in recentAlerts where alert.type == .memoryLeak {
    let processSnapshots = recentSnapshots.filter {
        $0.pid == alert.pid
    }
    // Analyze trend
}
```

---

### Retention Policy Integration

```swift
class DataRetentionManager {
    let store: SQLiteStore
    let retentionHours: Int = 72  // 3 days

    func runRetention() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(retentionHours * 3600))
        let timestamp = cutoff.timeIntervalSince1970

        store.deleteSnapshotsOlderThan(timestamp)
        store.deleteAlertsOlderThan(timestamp)

        let health = store.healthSnapshot()
        print("Retention complete. Snapshots: \(health.snapshotCount), Alerts: \(health.alertCount)")
    }
}
```

---

## Error Handling

```swift
do {
    let store = try SQLiteStore(url: databaseURL)

    store.recordSnapshot(timestamp: Date(), metrics: metrics, processes: processes)

    let health = store.healthSnapshot()
    if !health.quickCheckPassed {
        print("⚠️  Database may be corrupted")
    }
} catch {
    print("❌ Database error: \(error)")
}
```

---

## Performance Considerations

### Prepared Statement Caching

The store automatically caches prepared statements for:
- `INSERT` operations
- Frequent `SELECT` queries
- `DELETE` operations

This minimizes parsing overhead. No manual cache management needed.

### WAL Mode Benefits

- Non-blocking reads during writes
- Faster commits
- Efficient crash recovery

### Query Optimization

```swift
// ✓ Efficient: Uses timestamp index
let recent = store.getRecentSnapshots(hoursBack: 24)

// ✗ Inefficient: Full table scan
let all = store.getRecentSnapshots(hoursBack: 8760)  // Full year
// Better: Delete old data regularly instead
```

---

## Thread Safety

`SQLiteStore` is thread-safe for:
- Concurrent reads
- Sequential writes (serialized internally)

```swift
// Safe: Multiple threads can read simultaneously
DispatchQueue.concurrentPerform(iterations: 10) { i in
    let snapshots = store.getRecentSnapshots(hoursBack: 24)
}

// Safe: Writes are serialized
let queue = DispatchQueue(label: "db.write")
queue.async { store.recordSnapshot(...) }
queue.async { store.insertAlert(...) }  // Queued after snapshot
```

---

## Debugging

### Database Inspection

```bash
# Open database with sqlite3
sqlite3 ~/MemoryWatch/data/memorywatch.sqlite

# View schema
.schema

# Check table sizes
SELECT name, COUNT(*) as count FROM process_snapshots GROUP BY name;
SELECT type, COUNT(*) as count FROM memory_alerts GROUP BY type;

# WAL status
PRAGMA wal_info;
```

---

## Migration Guide

When database schema changes:

1. Schema is automatically migrated on first write
2. Old snapshots and alerts remain accessible
3. New fields have sensible defaults
4. See MASTER_PLAN.md for version history

---

## See Also

- [System Entitlements Guide](ENTITLEMENTS.md)
- [CLI Reference](CLI_REFERENCE.md)
- [Developer Integration Guide](DEVELOPER_GUIDE.md)

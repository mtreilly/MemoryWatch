import Foundation

// MARK: - Data Models

struct ProcessSnapshot: Codable {
    let pid: Int32
    let name: String
    let executablePath: String?
    let memoryMB: Double
    let percentMemory: Double
    let cpuPercent: Double
    let ioReadBps: Double
    let ioWriteBps: Double
    let rank: Int32?
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case pid
        case name
        case executablePath
        case memoryMB
        case percentMemory
        case cpuPercent
        case ioReadBps
        case ioWriteBps
        case rank
        case timestamp
    }

    init(pid: Int32,
         name: String,
         executablePath: String? = nil,
         memoryMB: Double,
         percentMemory: Double,
         cpuPercent: Double = 0,
         ioReadBps: Double = 0,
         ioWriteBps: Double = 0,
         rank: Int32? = nil,
         timestamp: Date) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.memoryMB = memoryMB
        self.percentMemory = percentMemory
        self.cpuPercent = cpuPercent
        self.ioReadBps = ioReadBps
        self.ioWriteBps = ioWriteBps
        self.rank = rank
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        name = try container.decode(String.self, forKey: .name)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        memoryMB = try container.decode(Double.self, forKey: .memoryMB)
        percentMemory = try container.decode(Double.self, forKey: .percentMemory)
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
        ioReadBps = try container.decodeIfPresent(Double.self, forKey: .ioReadBps) ?? 0
        ioWriteBps = try container.decodeIfPresent(Double.self, forKey: .ioWriteBps) ?? 0
        rank = try container.decodeIfPresent(Int32.self, forKey: .rank)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(executablePath, forKey: .executablePath)
        try container.encode(memoryMB, forKey: .memoryMB)
        try container.encode(percentMemory, forKey: .percentMemory)
        if cpuPercent != 0 { try container.encode(cpuPercent, forKey: .cpuPercent) }
        if ioReadBps != 0 { try container.encode(ioReadBps, forKey: .ioReadBps) }
        if ioWriteBps != 0 { try container.encode(ioWriteBps, forKey: .ioWriteBps) }
        try container.encodeIfPresent(rank, forKey: .rank)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public struct LeakSuspect {
    public let pid: Int32
    public let name: String
    public let initialMemoryMB: Double
    public let currentMemoryMB: Double
    public let growthMB: Double
    public let growthRate: Double // MB per hour
    public let firstSeen: Date
    public let lastSeen: Date
    public let suspicionLevel: SuspicionLevel

    public enum SuspicionLevel: String {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        case critical = "Critical"
    }
}

public struct MemoryAlert: Codable, Sendable {
    public let timestamp: Date
    public let type: AlertType
    public let message: String
    public let pid: Int32?
    public let processName: String?
    public let metadata: [String: String]?

    public enum AlertType: String, Codable, Sendable {
        case memoryLeak = "MEMORY_LEAK"
        case highSwap = "HIGH_SWAP"
        case rapidGrowth = "RAPID_GROWTH"
        case highMemory = "HIGH_MEMORY"
        case diagnosticHint = "DIAGNOSTIC_HINT"
        case systemPressure = "SYSTEM_PRESSURE"
        case datastoreWarning = "DATASTORE_WARNING"
    }
}

// MARK: - Process Monitor

public class ProcessMonitor {
    private let store: SQLiteStore?
    private var processHistory: [Int32: [ProcessSnapshot]] = [:]
    private var leakSuspects: [Int32: LeakSuspect] = [:]
    private var alerts: [MemoryAlert] = []
    private let alertLock = NSLock()
    private var lastSystemPressureLevel: String = "Normal"
    private var lastSwapAlertTimestamp: Date = .distantPast

    private var lastWALAlertTimestamp: Date = .distantPast
    private let walAlertCooldown: TimeInterval = 3600
    private let walAlertThresholdMB: Double
    private let walMonitoringEnabled: Bool

    public init(store: SQLiteStore? = nil, walAlertThresholdMB: Double = 150) {
        self.store = store
        self.walAlertThresholdMB = walAlertThresholdMB
        self.walMonitoringEnabled = RuntimeContext.walIntrospectionEnabled
    }

    // Thresholds
    private let rapidGrowthThresholdMB: Double = 100.0 // 100MB in single interval
    private let steadyGrowthThresholdMBPerHour: Double = 50.0 // 50MB/hour
    private let highMemoryThresholdMB: Double = 1024.0
    private let swapAlertThresholdMB: Double = 512.0
    private let minSamplesForAnalysis = 5

    func recordSnapshot(processes: [ProcessInfo], metrics: SystemMetrics, timestamp: Date = Date()) {
        var snapshotsToPersist: [ProcessSnapshot] = []

        for (index, process) in processes.enumerated() {
            let snapshot = ProcessSnapshot(
                pid: process.pid,
                name: process.name,
                executablePath: process.executablePath,
                memoryMB: process.memoryMB,
                percentMemory: process.percentMemory,
                cpuPercent: process.cpuPercent,
                ioReadBps: process.ioReadBps,
                ioWriteBps: process.ioWriteBps,
                rank: Int32(index + 1),
                timestamp: timestamp
            )

            if processHistory[process.pid] == nil {
                if let historical = store?.fetchRecentSamples(pid: process.pid, name: process.name, limit: 60), !historical.isEmpty {
                    processHistory[process.pid] = historical
                } else {
                    processHistory[process.pid] = []
                }
            }
            processHistory[process.pid]?.append(snapshot)

            snapshotsToPersist.append(snapshot)

            // Keep only last 1000 snapshots per process to prevent memory bloat
            if let count = processHistory[process.pid]?.count, count > 1000 {
                processHistory[process.pid]?.removeFirst(count - 1000)
            }
        }

        analyzeForLeaks()

        if !snapshotsToPersist.isEmpty {
            store?.recordSnapshot(timestamp: timestamp, metrics: metrics, processes: snapshotsToPersist)
        }

        evaluateSystemMetrics(metrics: metrics, timestamp: timestamp)
        if walMonitoringEnabled {
            evaluateDatastoreHealth(timestamp: timestamp)
        }
    }

    private func analyzeForLeaks() {
        let windowSize = 60

        for (pid, snapshots) in processHistory {
            guard snapshots.count >= minSamplesForAnalysis else { continue }

            let window = snapshots.suffix(windowSize)
            guard let evaluation = LeakHeuristics.evaluate(samples: window) else {
                leakSuspects.removeValue(forKey: pid)
                continue
            }

            // Ignore tiny growth/noise to limit false positives
            if evaluation.slopeMBPerHour < 8 || evaluation.growthMB < 60 {
                leakSuspects.removeValue(forKey: pid)
                continue
            }

            let suspicionLevel = LeakHeuristics.suspicionLevel(for: evaluation)
            if suspicionLevel == .low && evaluation.slopeMBPerHour < 12 {
                leakSuspects.removeValue(forKey: pid)
                continue
            }

            guard let first = snapshots.first, let last = snapshots.last else { continue }
            let growthFromStart = max(0, last.memoryMB - first.memoryMB)

            let suspect = LeakSuspect(
                pid: pid,
                name: last.name,
                initialMemoryMB: first.memoryMB,
                currentMemoryMB: last.memoryMB,
                growthMB: max(growthFromStart, evaluation.growthMB),
                growthRate: evaluation.slopeMBPerHour,
                firstSeen: first.timestamp,
                lastSeen: last.timestamp,
                suspicionLevel: suspicionLevel
            )

            leakSuspects[pid] = suspect

            let recentSnapshots = snapshots.suffix(6)
            if let recentFirst = recentSnapshots.first, let recentLast = recentSnapshots.last {
                let recentGrowth = recentLast.memoryMB - recentFirst.memoryMB
                if recentGrowth > rapidGrowthThresholdMB {
                    createAlert(
                        type: .rapidGrowth,
                        message: "\(last.name) grew \(String(format: "%.0f", recentGrowth))MB in last scans",
                        pid: pid,
                        processName: last.name
                    )
                }
            }

            if suspicionLevel == .high || suspicionLevel == .critical {
                createAlert(
                    type: .memoryLeak,
                    message: "Leak suspect: \(last.name) +\(String(format: "%.1f", evaluation.slopeMBPerHour))MB/hr (r²=\(String(format: "%.2f", evaluation.rSquared)), MAD=\(String(format: "%.1f", evaluation.medianAbsoluteDeviation)))",
                    pid: pid,
                    processName: last.name
                )
            }

            if suspicionLevel == .medium && evaluation.slopeMBPerHour >= 35 {
                createAlert(
                    type: .memoryLeak,
                    message: "Leak suspect (medium): \(last.name) slope \(String(format: "%.1f", evaluation.slopeMBPerHour))MB/hr",
                    pid: pid,
                    processName: last.name
                )
            }

            if last.memoryMB > highMemoryThresholdMB {
                createAlert(
                    type: .highMemory,
                    message: "\(last.name) using \(String(format: "%.0f", last.memoryMB))MB",
                    pid: pid,
                    processName: last.name
                )
            }

            emitDiagnosticHintsIfNeeded(snapshot: last, suspicionLevel: suspicionLevel)
        }

        cleanupOldProcesses()
    }

    private func cleanupOldProcesses() {
        let now = Date()
        let staleThreshold: TimeInterval = 3600 // 1 hour

        processHistory = processHistory.filter { _, snapshots in
            guard let lastSnapshot = snapshots.last else { return false }
            return now.timeIntervalSince(lastSnapshot.timestamp) < staleThreshold
        }

        leakSuspects = leakSuspects.filter { pid, _ in
            processHistory[pid] != nil
        }
    }

    private func createAlert(type: MemoryAlert.AlertType, message: String, pid: Int32?, processName: String?, metadata: [String: String]? = nil) {
        let alert = MemoryAlert(
            timestamp: Date(),
            type: type,
            message: message,
            pid: pid,
            processName: processName,
            metadata: metadata
        )

        recordAlert(alert)
    }

    public func recordAlert(_ alert: MemoryAlert, deduplicationWindow: TimeInterval = 300) {
        var shouldPersist = false

        alertLock.lock()
        let isDuplicate = alerts.contains {
            $0.type == alert.type &&
            $0.pid == alert.pid &&
            $0.message == alert.message &&
            abs(alert.timestamp.timeIntervalSince($0.timestamp)) < deduplicationWindow
        }

        if !isDuplicate {
            alerts.append(alert)
            shouldPersist = true
        }
        alertLock.unlock()

        if shouldPersist {
            store?.insertAlert(alert)
        }
    }

    private func evaluateSystemMetrics(metrics: SystemMetrics, timestamp: Date) {
        if metrics.swapUsedMB >= swapAlertThresholdMB {
            if lastSwapAlertTimestamp == .distantPast || timestamp.timeIntervalSince(lastSwapAlertTimestamp) > 1800 {
                let message = "Swap usage high: \(String(format: "%.0f", metrics.swapUsedMB))MB / \(String(format: "%.0f", metrics.swapTotalMB))MB"
                let metadata: [String: String] = [
                    "swap_used_mb": String(format: "%.0f", metrics.swapUsedMB),
                    "swap_total_mb": String(format: "%.0f", metrics.swapTotalMB),
                    "pressure": metrics.pressure
                ]
                createAlert(type: .highSwap,
                            message: message,
                            pid: nil,
                            processName: nil,
                            metadata: metadata)
                lastSwapAlertTimestamp = timestamp
            }
        } else {
            lastSwapAlertTimestamp = .distantPast
        }

        if metrics.pressure == "Critical", lastSystemPressureLevel != "Critical" {
            let message = "Memory pressure critical (free \(String(format: "%.1f", metrics.freeMemoryGB))GB)"
            let metadata: [String: String] = [
                "pressure": metrics.pressure,
                "free_gb": String(format: "%.2f", metrics.freeMemoryGB),
                "used_gb": String(format: "%.2f", metrics.usedMemoryGB)
            ]
            createAlert(type: .systemPressure,
                        message: message,
                        pid: nil,
                        processName: nil,
                        metadata: metadata)
        }

        lastSystemPressureLevel = metrics.pressure
    }

    private func evaluateDatastoreHealth(timestamp: Date) {
        guard let store else { return }
        guard walAlertThresholdMB > 0 else { return }
        let walSizeBytes = store.currentWALSizeBytes()
        let thresholdBytes = UInt64(walAlertThresholdMB * 1024 * 1024)

        if walSizeBytes >= thresholdBytes {
            if lastWALAlertTimestamp == .distantPast || timestamp.timeIntervalSince(lastWALAlertTimestamp) > walAlertCooldown {
                let message = "Datastore WAL size high: \(formatBytes(walSizeBytes)) (threshold \(formatBytes(thresholdBytes)))"
                let metadata: [String: String] = [
                    "wal_size_bytes": String(walSizeBytes),
                    "threshold_bytes": String(thresholdBytes)
                ]
                createAlert(type: .datastoreWarning,
                            message: message,
                            pid: nil,
                            processName: nil,
                            metadata: metadata)
                lastWALAlertTimestamp = timestamp
            }
        } else if walSizeBytes < thresholdBytes / 2 {
            lastWALAlertTimestamp = .distantPast
        }
    }

    private func emitDiagnosticHintsIfNeeded(snapshot: ProcessSnapshot, suspicionLevel: LeakSuspect.SuspicionLevel) {
        guard suspicionLevel == .medium || suspicionLevel == .high || suspicionLevel == .critical else {
            return
        }

        let suggestions = RuntimeDiagnostics.suggestions(pid: snapshot.pid, name: snapshot.name, executablePath: snapshot.executablePath)
        for suggestion in suggestions {
            var message = "\(suggestion.title): \(suggestion.command)"
            if let note = suggestion.note {
                message.append(" (\(note))")
            }
            if let path = suggestion.artifactPath {
                message.append(" -> \(path)")
            }

            var metadata: [String: String] = [
                "title": suggestion.title,
                "command": suggestion.command
            ]
            if let note = suggestion.note {
                metadata["note"] = note
            }
            if let path = suggestion.artifactPath {
                metadata["artifact_path"] = path
            }

            createAlert(type: .diagnosticHint, message: message, pid: snapshot.pid, processName: snapshot.name, metadata: metadata)
        }
    }

    public func getLeakSuspects(minLevel: LeakSuspect.SuspicionLevel = .medium) -> [LeakSuspect] {
        let levelRanks: [LeakSuspect.SuspicionLevel: Int] = [
            .low: 0,
            .medium: 1,
            .high: 2,
            .critical: 3
        ]

        let minRank = levelRanks[minLevel] ?? 1

        return leakSuspects.values
            .filter { levelRanks[$0.suspicionLevel]! >= minRank }
            .sorted { $0.growthRate > $1.growthRate }
    }

    public func getRecentAlerts(count: Int = 20) -> [MemoryAlert] {
        alertLock.lock()
        let recent = Array(alerts.suffix(count))
        alertLock.unlock()
        return recent
    }

    func latestSnapshot(for pid: Int32) -> ProcessSnapshot? {
        return processHistory[pid]?.last
    }

    public func getStats() -> (processesTracked: Int, totalSnapshots: Int, alertsCount: Int) {
        let processesTracked = processHistory.count
        let totalSnapshots = processHistory.values.reduce(0) { $0 + $1.count }
        let alertsCount = alertsCount()
        return (processesTracked, totalSnapshots, alertsCount)
    }

    public func generateJSONReport(minLevel: LeakSuspect.SuspicionLevel = .medium, recentAlertCount: Int = 10) -> String {
        struct ReportJSON: Codable {
            struct Suspect: Codable {
                let pid: Int32
                let name: String
                let initialMemoryMB: Double
                let currentMemoryMB: Double
                let growthMB: Double
                let growthRate: Double
                let firstSeen: Date
                let lastSeen: Date
                let level: String
                let durationSeconds: Double
            }
            struct Stats: Codable {
                let processesTracked: Int
                let totalSnapshots: Int
                let alertsCount: Int
            }
            let suspects: [Suspect]
            let alerts: [MemoryAlert]
            let stats: Stats
            let generatedAt: Date
        }

        let suspects = getLeakSuspects(minLevel: minLevel).map { s in
            ReportJSON.Suspect(
                pid: s.pid,
                name: s.name,
                initialMemoryMB: s.initialMemoryMB,
                currentMemoryMB: s.currentMemoryMB,
                growthMB: s.growthMB,
                growthRate: s.growthRate,
                firstSeen: s.firstSeen,
                lastSeen: s.lastSeen,
                level: s.suspicionLevel.rawValue,
                durationSeconds: s.lastSeen.timeIntervalSince(s.firstSeen)
            )
        }
        let alerts = getRecentAlerts(count: recentAlertCount)
        let st = getStats()
        let report = ReportJSON(
            suspects: suspects,
            alerts: alerts,
            stats: .init(processesTracked: st.processesTracked, totalSnapshots: st.totalSnapshots, alertsCount: st.alertsCount),
            generatedAt: Date()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = (try? enc.encode(report)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public func getProcessTrend(pid: Int32) -> String? {
        guard let snapshots = processHistory[pid], snapshots.count >= 3 else {
            return nil
        }

        let recent = snapshots.suffix(10)
        let growths = zip(recent.dropLast(), recent.dropFirst()).map { $1.memoryMB - $0.memoryMB }
        let avgGrowth = growths.reduce(0, +) / Double(growths.count)

        if avgGrowth > 10 {
            return "📈 Growing (\(String(format: "+%.0f", avgGrowth))MB/interval)"
        } else if avgGrowth < -10 {
            return "📉 Shrinking (\(String(format: "%.0f", avgGrowth))MB/interval)"
        } else {
            return "➡️ Stable"
        }
    }

    public func generateReport() -> String {
        var report = """

        ═══════════════════════════════════════════════════════════════
        MemoryWatch Report - \(formatDate(Date()))
        ═══════════════════════════════════════════════════════════════

        """

        // Leak Suspects
        let suspects = getLeakSuspects(minLevel: .medium)
        if suspects.isEmpty {
            report += "\n✅ No memory leaks detected\n"
        } else {
            report += "\n⚠️  Leak Suspects (\(suspects.count) found)\n"
            report += "─────────────────────────────────────────────────────────────\n"
            for suspect in suspects.prefix(10) {
                let icon = iconForLevel(suspect.suspicionLevel)
                let duration = formatDuration(suspect.lastSeen.timeIntervalSince(suspect.firstSeen))

                report += """
                \(icon) \(suspect.name) (PID \(suspect.pid))
                   Level: \(suspect.suspicionLevel.rawValue)
                   Growth: \(String(format: "%.0f", suspect.initialMemoryMB))MB → \(String(format: "%.0f", suspect.currentMemoryMB))MB (+\(String(format: "%.0f", suspect.growthMB))MB)
                   Rate: \(String(format: "%.1f", suspect.growthRate)) MB/hour
                   Duration: \(duration)

                """
            }
        }

        // Recent Alerts
        let recentAlerts = getRecentAlerts(count: 10)
        if !recentAlerts.isEmpty {
            report += "\n🔔 Recent Alerts (\(recentAlerts.count))\n"
            report += "─────────────────────────────────────────────────────────────\n"
            for alert in recentAlerts.reversed() {
                let time = formatTime(alert.timestamp)
                report += "[\(time)] \(alert.type.rawValue): \(alert.message)\n"
            }
        }

        // Statistics
        report += "\n📊 Monitoring Statistics\n"
        report += "─────────────────────────────────────────────────────────────\n"
        report += "Processes tracked: \(processHistory.count)\n"
        report += "Total snapshots: \(processHistory.values.reduce(0) { $0 + $1.count })\n"
        report += "Total alerts: \(alertsCount())\n"

        report += "\n═══════════════════════════════════════════════════════════════\n"

        return report
    }

    // MARK: - Helper Functions

    private func iconForLevel(_ level: LeakSuspect.SuspicionLevel) -> String {
        switch level {
        case .low: return "🟡"
        case .medium: return "🟠"
        case .high: return "🔴"
        case .critical: return "🚨"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units: [(Double, String)] = [
            (1024 * 1024 * 1024, "GB"),
            (1024 * 1024, "MB"),
            (1024, "KB")
        ]
        let value = Double(bytes)
        for (divisor, suffix) in units {
            if value >= divisor {
                return String(format: "%.1f %@", value / divisor, suffix)
            }
        }
        return "\(bytes) B"
    }

    private func alertsCount() -> Int {
        alertLock.lock()
        let count = alerts.count
        alertLock.unlock()
        return count
    }

    // MARK: - Persistence

    public func saveState(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let snapshots = processHistory.values.flatMap { $0 }
        let data = try encoder.encode(snapshots)
        try data.write(to: url)
    }

    public func loadState(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshots = try decoder.decode([ProcessSnapshot].self, from: data)

        // Rebuild history
        for snapshot in snapshots {
            if processHistory[snapshot.pid] == nil {
                processHistory[snapshot.pid] = []
            }
            processHistory[snapshot.pid]?.append(snapshot)
        }

        analyzeForLeaks()
    }
}

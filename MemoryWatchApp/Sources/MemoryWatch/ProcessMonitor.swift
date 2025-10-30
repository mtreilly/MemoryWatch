import Foundation

// MARK: - Data Models

struct ProcessSnapshot: Codable {
    let pid: Int32
    let name: String
    let memoryMB: Double
    let percentMemory: Double
    let timestamp: Date
}

struct LeakSuspect {
    let pid: Int32
    let name: String
    let initialMemoryMB: Double
    let currentMemoryMB: Double
    let growthMB: Double
    let growthRate: Double // MB per hour
    let firstSeen: Date
    let lastSeen: Date
    let suspicionLevel: SuspicionLevel

    enum SuspicionLevel: String {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        case critical = "Critical"
    }
}

struct MemoryAlert: Codable {
    let timestamp: Date
    let type: AlertType
    let message: String
    let pid: Int32?
    let processName: String?

    enum AlertType: String, Codable {
        case memoryLeak = "MEMORY_LEAK"
        case highSwap = "HIGH_SWAP"
        case rapidGrowth = "RAPID_GROWTH"
        case highMemory = "HIGH_MEMORY"
    }
}

// MARK: - Process Monitor

class ProcessMonitor {
    private var processHistory: [Int32: [ProcessSnapshot]] = [:]
    private var leakSuspects: [Int32: LeakSuspect] = [:]
    private var alerts: [MemoryAlert] = []

    // Thresholds
    private let rapidGrowthThresholdMB: Double = 100.0 // 100MB in single interval
    private let steadyGrowthThresholdMBPerHour: Double = 50.0 // 50MB/hour
    private let highMemoryThresholdMB: Double = 1024.0
    private let swapAlertThresholdMB: Double = 512.0
    private let minSamplesForAnalysis = 5

    func recordSnapshot(processes: [(pid: Int32, name: String, memoryMB: Double, percentMemory: Double)], timestamp: Date = Date()) {

        for process in processes {
            let snapshot = ProcessSnapshot(
                pid: process.pid,
                name: process.name,
                memoryMB: process.memoryMB,
                percentMemory: process.percentMemory,
                timestamp: timestamp
            )

            if processHistory[process.pid] == nil {
                processHistory[process.pid] = []
            }
            processHistory[process.pid]?.append(snapshot)

            // Keep only last 1000 snapshots per process to prevent memory bloat
            if let count = processHistory[process.pid]?.count, count > 1000 {
                processHistory[process.pid]?.removeFirst(count - 1000)
            }
        }

        analyzeForLeaks()
    }

    private func analyzeForLeaks() {
        for (pid, snapshots) in processHistory {
            guard snapshots.count >= minSamplesForAnalysis else { continue }

            let first = snapshots.first!
            let last = snapshots.last!
            let growthMB = last.memoryMB - first.memoryMB

            // Calculate time difference in hours
            let timeInterval = last.timestamp.timeIntervalSince(first.timestamp)
            let hours = timeInterval / 3600.0
            guard hours > 0 else { continue }

            let growthRate = growthMB / hours

            // Detect rapid growth in recent samples
            let recentSnapshots = snapshots.suffix(10)
            let recentGrowth = recentSnapshots.last!.memoryMB - recentSnapshots.first!.memoryMB

            // Determine suspicion level
            var suspicionLevel: LeakSuspect.SuspicionLevel = .low

            if recentGrowth > rapidGrowthThresholdMB {
                suspicionLevel = .critical
                createAlert(
                    type: .rapidGrowth,
                    message: "\(last.name) grew \(String(format: "%.0f", recentGrowth))MB rapidly",
                    pid: pid,
                    processName: last.name
                )
            } else if growthRate > steadyGrowthThresholdMBPerHour * 2 {
                suspicionLevel = .high
            } else if growthRate > steadyGrowthThresholdMBPerHour {
                suspicionLevel = .medium
            } else if growthMB > 50 && growthRate > 10 {
                suspicionLevel = .low
            }

            // Only track if there's actual growth
            if growthMB > 10 {
                let suspect = LeakSuspect(
                    pid: pid,
                    name: last.name,
                    initialMemoryMB: first.memoryMB,
                    currentMemoryMB: last.memoryMB,
                    growthMB: growthMB,
                    growthRate: growthRate,
                    firstSeen: first.timestamp,
                    lastSeen: last.timestamp,
                    suspicionLevel: suspicionLevel
                )

                leakSuspects[pid] = suspect

                // Create alert for high suspicion levels
                if suspicionLevel == .high || suspicionLevel == .critical {
                    createAlert(
                        type: .memoryLeak,
                        message: "Potential leak: \(last.name) grew \(String(format: "%.0f", growthMB))MB (\(String(format: "%.1f", growthRate))MB/hr)",
                        pid: pid,
                        processName: last.name
                    )
                }
            }

            // Check for high memory usage
            if last.memoryMB > highMemoryThresholdMB {
                createAlert(
                    type: .highMemory,
                    message: "\(last.name) using \(String(format: "%.0f", last.memoryMB))MB",
                    pid: pid,
                    processName: last.name
                )
            }
        }

        // Clean up old suspects that are no longer running
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

    private func createAlert(type: MemoryAlert.AlertType, message: String, pid: Int32?, processName: String?) {
        let alert = MemoryAlert(
            timestamp: Date(),
            type: type,
            message: message,
            pid: pid,
            processName: processName
        )

        // Avoid duplicate alerts (same type + process within 5 minutes)
        let recentAlerts = alerts.filter {
            Date().timeIntervalSince($0.timestamp) < 300 &&
            $0.type == type &&
            $0.pid == pid
        }

        if recentAlerts.isEmpty {
            alerts.append(alert)
        }
    }

    func getLeakSuspects(minLevel: LeakSuspect.SuspicionLevel = .medium) -> [LeakSuspect] {
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

    func getRecentAlerts(count: Int = 20) -> [MemoryAlert] {
        return Array(alerts.suffix(count))
    }

    func getStats() -> (processesTracked: Int, totalSnapshots: Int, alertsCount: Int) {
        let processesTracked = processHistory.count
        let totalSnapshots = processHistory.values.reduce(0) { $0 + $1.count }
        let alertsCount = alerts.count
        return (processesTracked, totalSnapshots, alertsCount)
    }

    func generateJSONReport(minLevel: LeakSuspect.SuspicionLevel = .medium, recentAlertCount: Int = 10) -> String {
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

    func getProcessTrend(pid: Int32) -> String? {
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

    func generateReport() -> String {
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
        report += "Total alerts: \(alerts.count)\n"

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

    // MARK: - Persistence

    func saveState(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let snapshots = processHistory.values.flatMap { $0 }
        let data = try encoder.encode(snapshots)
        try data.write(to: url)
    }

    func loadState(from url: URL) throws {
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

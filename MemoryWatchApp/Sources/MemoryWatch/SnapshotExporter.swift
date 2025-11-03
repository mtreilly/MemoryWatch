import Foundation
import AppKit

/// Exports memory snapshots to JSON and CSV formats for analysis and sharing
public enum SnapshotExporter {

    /// Export current snapshot to JSON format
    public static func exportSnapshotAsJSON(_ snapshot: MenuBarState.Snapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let exportData = SnapshotExportData(snapshot: snapshot)
        return try? encoder.encode(exportData)
    }

    /// Export historical data to CSV format
    public static func exportHistoryAsCSV(_ points: [SnapshotHistoryPoint]) -> Data? {
        var csv = "Timestamp,Used Memory (GB),Swap Used (MB),SSD Wear (MB),Top Process\n"

        let dateFormatter = ISO8601DateFormatter()

        for point in points {
            let timestamp = dateFormatter.string(from: point.timestamp)
            let usedMemory = String(format: "%.2f", point.usedMemoryGB)
            let swapUsed = String(format: "%.0f", point.swapUsedMB)
            let ssdWear = String(format: "%.2f", point.ssdWearMB)
            let processName = point.topProcess?.name ?? "N/A"

            let row = "\(timestamp),\(usedMemory),\(swapUsed),\(ssdWear),\(processName)\n"
            csv.append(row)
        }

        return csv.data(using: .utf8)
    }

    /// Save data to file and open in Finder
    public static func saveAndReveal(data: Data, filename: String) -> Bool {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let fileURL = desktopURL.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL)
            // Open file in Finder
            NSWorkspace.shared.open(fileURL)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Export Data Structures

private struct SnapshotExportData: Encodable {
    let exportTimestamp: String
    let memoryMetrics: MemoryMetricsData
    let topProcess: ProcessExportData?
    let topLeakSuspect: LeakSuspectExportData?
    let systemAlerts: [MemoryAlertData]
    let notificationPreferences: NotificationPreferencesData

    init(snapshot: MenuBarState.Snapshot) {
        let dateFormatter = ISO8601DateFormatter()
        self.exportTimestamp = dateFormatter.string(from: snapshot.timestamp)

        self.memoryMetrics = MemoryMetricsData(
            usedGB: snapshot.metrics.usedMemoryGB,
            freeGB: snapshot.metrics.freeMemoryGB,
            swapUsedMB: snapshot.metrics.swapUsedMB,
            swapTotalMB: snapshot.metrics.swapTotalMB,
            pressure: snapshot.metrics.pressure
        )

        self.topProcess = snapshot.topProcess.map { ProcessExportData(from: $0) }
        self.topLeakSuspect = snapshot.topLeakSuspect.map { LeakSuspectExportData(from: $0) }
        self.systemAlerts = snapshot.systemAlerts.map { MemoryAlertData(from: $0) }
        self.notificationPreferences = NotificationPreferencesData(from: snapshot.notificationPreferences)
    }

    enum CodingKeys: String, CodingKey {
        case exportTimestamp = "export_timestamp"
        case memoryMetrics = "memory_metrics"
        case topProcess = "top_process"
        case topLeakSuspect = "top_leak_suspect"
        case systemAlerts = "system_alerts"
        case notificationPreferences = "notification_preferences"
    }
}

private struct MemoryMetricsData: Encodable {
    let usedGB: Double
    let freeGB: Double
    let swapUsedMB: Double
    let swapTotalMB: Double
    let pressure: String

    enum CodingKeys: String, CodingKey {
        case usedGB = "used_gb"
        case freeGB = "free_gb"
        case swapUsedMB = "swap_used_mb"
        case swapTotalMB = "swap_total_mb"
        case pressure
    }
}

private struct ProcessExportData: Encodable {
    let name: String
    let pid: Int32
    let memoryMB: Double
    let cpuPercent: Double
    let executablePath: String?

    init(from process: ProcessInfo) {
        self.name = process.name
        self.pid = process.pid
        self.memoryMB = process.memoryMB
        self.cpuPercent = process.cpuPercent
        self.executablePath = process.executablePath
    }

    enum CodingKeys: String, CodingKey {
        case name
        case pid
        case memoryMB = "memory_mb"
        case cpuPercent = "cpu_percent"
        case executablePath = "executable_path"
    }
}

private struct LeakSuspectExportData: Encodable {
    let name: String
    let pid: Int32
    let growthMB: Double
    let growthRate: Double
    let suspicionLevel: String

    init(from suspect: LeakSuspect) {
        self.name = suspect.name
        self.pid = suspect.pid
        self.growthMB = suspect.growthMB
        self.growthRate = suspect.growthRate
        self.suspicionLevel = suspect.suspicionLevel.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case name
        case pid
        case growthMB = "growth_mb"
        case growthRate = "growth_rate_mb_per_hour"
        case suspicionLevel = "suspicion_level"
    }
}

private struct MemoryAlertData: Encodable {
    let type: String
    let message: String
    let timestamp: String

    init(from alert: MemoryAlert) {
        self.type = alert.type.rawValue
        self.message = alert.message
        let dateFormatter = ISO8601DateFormatter()
        self.timestamp = dateFormatter.string(from: alert.timestamp)
    }
}

private struct NotificationPreferencesData: Encodable {
    let leakNotificationsEnabled: Bool
    let pressureNotificationsEnabled: Bool
    let quietHoursEnabled: Bool
    let quietHoursStart: String?
    let quietHoursEnd: String?
    let allowInterruptionsDuringQuietHours: Bool

    init(from prefs: NotificationPreferences) {
        self.leakNotificationsEnabled = prefs.leakNotificationsEnabled
        self.pressureNotificationsEnabled = prefs.pressureNotificationsEnabled
        self.quietHoursEnabled = prefs.quietHours != nil

        if let quiet = prefs.quietHours {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none

            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: quiet.timezoneIdentifier) ?? .current

            let startDate = cal.date(bySettingHour: quiet.startMinutes / 60, minute: quiet.startMinutes % 60, second: 0, of: Date())!
            let endDate = cal.date(bySettingHour: quiet.endMinutes / 60, minute: quiet.endMinutes % 60, second: 0, of: Date())!

            self.quietHoursStart = formatter.string(from: startDate)
            self.quietHoursEnd = formatter.string(from: endDate)
        } else {
            self.quietHoursStart = nil
            self.quietHoursEnd = nil
        }

        self.allowInterruptionsDuringQuietHours = prefs.allowInterruptionsDuringQuietHours
    }

    enum CodingKeys: String, CodingKey {
        case leakNotificationsEnabled = "leak_notifications_enabled"
        case pressureNotificationsEnabled = "pressure_notifications_enabled"
        case quietHoursEnabled = "quiet_hours_enabled"
        case quietHoursStart = "quiet_hours_start"
        case quietHoursEnd = "quiet_hours_end"
        case allowInterruptionsDuringQuietHours = "allow_interruptions_during_quiet_hours"
    }
}

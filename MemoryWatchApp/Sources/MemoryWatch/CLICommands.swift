import Foundation
import ArgumentParser

public struct SnapshotCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Show current memory snapshot")
    @Flag(name: .shortAndLong, help: "Output JSON instead of text") public var json: Bool = false
    @Option(name: .customLong("min-mem-mb"), help: "Minimum process memory to include (MB)") public var minMemMB: Double = 50
    @Option(name: .long, help: "Number of processes to show") public var top: Int = 15

    public init() {}

    public mutating func run() throws {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()
        CLI.showSnapshot(json: json, minMemMB: minMemMB, topN: top)
    }
}

public struct StatusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Show datastore health and monitoring status")

    public init() {}

    public mutating func run() throws {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()
        CLI.showStatus()
    }
}

public struct DaemonCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Run continuous monitoring daemon")
    @Option(name: .shortAndLong, help: "Scan interval seconds (defaults to preference)") public var interval: Double?
    @Option(name: .customLong("min-mem-mb"), help: "Minimum process memory to track (MB)") public var minMemMB: Double = 50
    @Option(name: .customLong("swap-warn-mb"), help: "Warn when swap used exceeds MB") public var swapWarnMB: Double = 1024
    @Option(name: .customLong("pageouts-warn-rate"), help: "Warn when pageouts/sec exceeds threshold") public var pageoutsWarnRate: Double = 100
    @Option(name: .customLong("autosave-every"), help: "Autosave state every N scans") public var autosaveEvery: Int = 10
    @Option(name: .customLong("report-every"), help: "Print report every N scans") public var reportEvery: Int = 120

    public init() {}

    public mutating func run() throws {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()
        CLI.runDaemon(intervalOverride: interval,
                      minMemMB: minMemMB,
                      swapWarnMB: swapWarnMB,
                      pageoutsWarnRate: pageoutsWarnRate,
                      autosaveEvery: autosaveEvery,
                      reportEvery: reportEvery)
    }
}

public struct ReportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Display leak detection report")
    @Flag(name: .shortAndLong, help: "Output JSON instead of text") public var json: Bool = false
    @Option(name: .customLong("min-level"), help: "Minimum suspicion level in JSON: low|medium|high|critical") public var minLevel: String?
    @Option(name: .customLong("recent-alerts"), help: "Number of recent alerts to include in JSON") public var recentAlerts: Int = 10

    public init() {}

    public mutating func run() throws { CLI.showReport(json: json, minLevel: minLevel, recentAlerts: recentAlerts) }
}

public struct SuspectsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "List memory leak suspects")
    @Option(name: .customLong("min-level"), help: "Minimum suspicion level: low|medium|high|critical") public var minLevel: String?
    @Option(name: .long, help: "Limit number of suspects") public var max: Int?
    @Flag(name: .shortAndLong, help: "Output JSON instead of text") public var json: Bool = false

    public init() {}

    public mutating func run() throws { CLI.showSuspects(minLevel: minLevel, max: max, json: json) }
}

public struct IOCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Show top disk I/O processes")
    @Option(name: .customLong("sample-ms"), help: "Sampling duration in milliseconds") public var sampleMs: Int = 600
    @Option(name: .customLong("min-mem-mb"), help: "Minimum process memory to include (MB)") public var minMemMB: Double = 10
    @Option(name: .long, help: "Number of processes to show") public var top: Int = 10
    @Option(name: .long, help: "Sort by 'write' or 'read' (display both)") public var sort: String = "write"

    public init() {}

    public mutating func run() throws { CLI.showIO(sampleMs: sampleMs, minMemMB: minMemMB, topN: top, sortBy: sort) }
}

public struct DanglingFilesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Find deleted but open files")

    public init() {}

    public mutating func run() throws { CLI.findDanglingFiles() }
}

public struct PortsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Show processes on port range")
    @Argument(help: "Port range like 3000-3010") public var range: String

    public init() {}

    public mutating func run() throws { CLI.showPortQuery(arguments: ["--ports", range]) }
}

public struct CheckPortCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Check if a specific port is available")
    @Argument(help: "Port number") public var port: Int

    public init() {}

    public mutating func run() throws { CLI.checkPort(arguments: ["--check-port", String(port)]) }
}

public struct FindFreePortCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Find free ports in range")
    @Argument(help: "Range like 8000-9000") public var range: String
    @Argument(help: "Count to find", transform: { Int($0) ?? 1 }) public var count: Int = 1

    public init() {}

    public mutating func run() throws { CLI.findFreePorts(arguments: ["--find-free-port", range, String(count)]) }
}

public struct KillCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Safely terminate process (SIGTERM)")
    @Argument(help: "PID") public var pid: Int

    public init() {}

    public mutating func run() throws { CLI.killProcess(arguments: ["--kill", String(pid)], force: false) }
}

public struct ForceKillCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Force kill process (SIGKILL)")
    @Argument(help: "PID") public var pid: Int

    public init() {}

    public mutating func run() throws { CLI.killProcess(arguments: ["--force-kill", String(pid)], force: true) }
}

public struct KillPatternCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Kill all processes matching regex pattern")
    @Argument(help: "Regex pattern") public var pattern: String
    @Flag(help: "Force kill (SIGKILL)") public var force: Bool = false

    public init() {}

    public mutating func run() throws {
        var args = ["--kill-pattern", pattern]
        if force { args.append("--force") }
        CLI.killProcessPattern(arguments: args)
    }
}

public struct InteractiveKillCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Interactive multi-process kill")
    @Option(help: "Port range like 3000-3010") public var ports: String?

    public init() {}

    public mutating func run() throws {
        var args = ["--interactive-kill"]
        if let r = ports { args += ["--ports", r] }
        CLI.interactiveKill(arguments: args)
    }
}

public struct HelpCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Show detailed help")

    public init() {}

    public mutating func run() throws { CLI.showHelp() }
}

public struct DiagnosticsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "Collect runtime diagnostics for a process")
    @Argument(help: "PID to inspect") public var pid: Int32

    public init() {}

    public mutating func run() throws {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()

        guard let process = ProcessCollector.getProcessInfo(pid: pid) else {
            throw ValidationError("PID \(pid) not found")
        }

        let store = try? SQLiteStore(url: MemoryWatchPaths.databaseFile)
        let suggestions = RuntimeDiagnostics.suggestions(pid: pid, name: process.name, executablePath: process.executablePath)

        if suggestions.isEmpty {
            throw ValidationError("No diagnostic suggestions available for \(process.name)")
        }

        print("Collecting diagnostics for PID \(pid) (\(process.name))...")

        for suggestion in suggestions {
            print("\n▶︎ \(suggestion.title)")
            print("$ \(suggestion.command)")
            let result = DiagnosticExecutor.run(suggestion: suggestion)
            if let code = result.exitCode {
                print("Exit code: \(code)")
            }
            if !result.stdout.isEmpty {
                print(result.stdout)
            }
            if !result.stderr.isEmpty {
                print(result.stderr)
            }

            var metadata: [String: String] = [
                "title": suggestion.title,
                "command": suggestion.command
            ]
            if let note = suggestion.note {
                metadata["note"] = note
            }
            if let artifact = result.artifactURL?.path {
                metadata["artifact_path"] = artifact
                metadata["artifact_exists"] = "true"
            } else if let path = suggestion.artifactPath {
                metadata["artifact_path"] = NSString(string: path).expandingTildeInPath
                metadata["artifact_exists"] = "false"
            }

            var message = "Diagnostics executed: \(suggestion.title)"
            if let artifact = metadata["artifact_path"] {
                message += " -> \(artifact)"
            }

            if let store {
                let alert = MemoryAlert(
                    timestamp: Date(),
                    type: .diagnosticHint,
                    message: message,
                    pid: pid,
                    processName: process.name,
                    metadata: metadata
                )
                store.insertAlert(alert)
            }
        }

        print("\nDiagnostics complete. Artifacts saved where available.")
    }
}

public struct NotificationsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(abstract: "View or update notification preferences.")

    @Flag(name: .customLong("show"), help: "Show current notification preferences.") public var show: Bool = false
    @Flag(name: .customLong("disable-quiet-hours"), help: "Disable quiet hours entirely.") public var disableQuietHours: Bool = false
    @Option(name: .customLong("quiet-start"), help: "Quiet hours start time (HH or HH:MM, 24-hour clock).") public var quietStart: String?
    @Option(name: .customLong("quiet-end"), help: "Quiet hours end time (HH or HH:MM, 24-hour clock).") public var quietEnd: String?
    @Option(name: .customLong("quiet-policy"), help: "Notification policy during quiet hours: allow | hold.") public var quietPolicy: String?
    @Option(name: .customLong("timezone"), help: "Time zone identifier for quiet hours (default: system).") public var timezone: String?
    @Option(name: .customLong("leak-notifications"), help: "Enable leak notifications: on | off") public var leakNotifications: String?
    @Option(name: .customLong("pressure-notifications"), help: "Enable pressure notifications: on | off") public var pressureNotifications: String?

    public init() {}

    public mutating func run() async throws {
        var prefs = await NotificationPreferencesStore.load()
        var updated = false

        if disableQuietHours && (quietStart != nil || quietEnd != nil || timezone != nil) {
            throw ValidationError("Quiet hours cannot be disabled and reconfigured simultaneously.")
        }

        if disableQuietHours {
            if prefs.quietHours != nil {
                prefs.quietHours = nil
                updated = true
            }
        } else if quietStart != nil || quietEnd != nil || timezone != nil {
            var quiet = prefs.quietHours ?? NotificationPreferences.QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)

            if let startString = quietStart {
                quiet.startMinutes = try parseTime(startString)
                updated = true
            }
            if let endString = quietEnd {
                quiet.endMinutes = try parseTime(endString)
                updated = true
            }
            if let tz = timezone {
                guard TimeZone(identifier: tz) != nil else {
                    throw ValidationError("Unknown time zone identifier '\(tz)'.")
                }
                quiet.timezoneIdentifier = tz
                updated = true
            }
            prefs.quietHours = quiet
        }

        if let policyString = quietPolicy {
            let policy = policyString.lowercased()
            switch policy {
            case "allow":
                if !prefs.allowInterruptionsDuringQuietHours {
                    prefs.allowInterruptionsDuringQuietHours = true
                    updated = true
                }
            case "hold":
                if prefs.allowInterruptionsDuringQuietHours {
                    prefs.allowInterruptionsDuringQuietHours = false
                    updated = true
                }
            default:
                throw ValidationError("quiet-policy must be 'allow' or 'hold'.")
            }
        }

        if let leakSetting = leakNotifications {
            let enableLeaks = try parseToggle(leakSetting, optionName: "leak-notifications")
            if prefs.leakNotificationsEnabled != enableLeaks {
                prefs.leakNotificationsEnabled = enableLeaks
                updated = true
            }
        }

        if let pressureSetting = pressureNotifications {
            let enablePressure = try parseToggle(pressureSetting, optionName: "pressure-notifications")
            if prefs.pressureNotificationsEnabled != enablePressure {
                prefs.pressureNotificationsEnabled = enablePressure
                updated = true
            }
        }

        if updated {
            try await NotificationPreferencesStore.save(prefs)
            print("✅ Notification preferences updated.\n")
        }

        if show || !updated {
            printSummary(prefs)
        }
    }

    private func parseTime(_ value: String) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 1 || parts.count == 2, !parts.isEmpty else {
            throw ValidationError("Invalid time '\(value)'. Use HH or HH:MM.")
        }

        guard let hour = Int(parts[0]), (0...23).contains(hour) else {
            throw ValidationError("Hour must be between 0 and 23.")
        }
        let minute: Int
        if parts.count == 2 {
            guard let mins = Int(parts[1]), (0...59).contains(mins) else {
                throw ValidationError("Minutes must be between 0 and 59.")
            }
            minute = mins
        } else {
            minute = 0
        }
        return hour * 60 + minute
    }

    private func parseToggle(_ value: String, optionName: String) throws -> Bool {
        let lower = value.lowercased()
        switch lower {
        case "on", "enable", "enabled", "true":
            return true
        case "off", "disable", "disabled", "false":
            return false
        default:
            throw ValidationError("\(optionName) expects 'on' or 'off'.")
        }
    }

    private func printSummary(_ prefs: NotificationPreferences) {
        print("Notification Preferences")
        print("------------------------")
        if let quiet = prefs.quietHours {
            print("Quiet hours: \(quiet.description())")
        } else {
            print("Quiet hours: disabled")
        }
        print("Quiet hour policy: \(prefs.allowInterruptionsDuringQuietHours ? "allow deliveries" : "hold notifications")")
        print("Leak notifications: \(prefs.leakNotificationsEnabled ? "on" : "off")")
        print("Pressure notifications: \(prefs.pressureNotificationsEnabled ? "on" : "off")")
    }
}

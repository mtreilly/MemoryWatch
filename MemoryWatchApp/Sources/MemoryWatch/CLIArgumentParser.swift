import Foundation
import ArgumentParser

@main
struct MemoryWatchCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memwatch",
        abstract: "macOS Memory Monitoring & Leak Detection",
        version: "1.0",
        subcommands: [
            Snapshot.self,
            Daemon.self,
            Report.self,
            Suspects.self,
            IO.self,
            DanglingFiles.self,
            Ports.self,
            CheckPort.self,
            FindFreePort.self,
            Kill.self,
            ForceKill.self,
            KillPattern.self,
            InteractiveKill.self,
            HelpCommand.self
        ],
        defaultSubcommand: Snapshot.self
    )
}

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show current memory snapshot")
    @Flag(name: .shortAndLong, help: "Output JSON instead of text") var json: Bool = false
    @Option(name: .customLong("min-mem-mb"), help: "Minimum process memory to include (MB)") var minMemMB: Double = 50
    @Option(name: .long, help: "Number of processes to show") var top: Int = 15
    mutating func run() throws {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()
        CLI.showSnapshot(json: json, minMemMB: minMemMB, topN: top)
    }
}

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run continuous monitoring daemon")
    @Option(name: .shortAndLong, help: "Scan interval seconds") var interval: Double = 30
    @Option(name: .customLong("min-mem-mb"), help: "Minimum process memory to track (MB)") var minMemMB: Double = 50
    @Option(name: .customLong("swap-warn-mb"), help: "Warn when swap used exceeds MB") var swapWarnMB: Double = 1024
    @Option(name: .customLong("pageouts-warn-rate"), help: "Warn when pageouts/sec exceeds threshold") var pageoutsWarnRate: Double = 100
    @Option(name: .customLong("autosave-every"), help: "Autosave state every N scans") var autosaveEvery: Int = 10
    @Option(name: .customLong("report-every"), help: "Print report every N scans") var reportEvery: Int = 120
    mutating func run() throws {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()
        CLI.runDaemon(interval: interval,
                      minMemMB: minMemMB,
                      swapWarnMB: swapWarnMB,
                      pageoutsWarnRate: pageoutsWarnRate,
                      autosaveEvery: autosaveEvery,
                      reportEvery: reportEvery)
    }
}

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display leak detection report")
    @Flag(name: .shortAndLong, help: "Output JSON instead of text") var json: Bool = false
    @Option(name: .customLong("min-level"), help: "Minimum suspicion level in JSON: low|medium|high|critical") var minLevel: String?
    @Option(name: .customLong("recent-alerts"), help: "Number of recent alerts to include in JSON") var recentAlerts: Int = 10
    mutating func run() throws { CLI.showReport(json: json, minLevel: minLevel, recentAlerts: recentAlerts) }
}

struct Suspects: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List memory leak suspects")
    @Option(name: .customLong("min-level"), help: "Minimum suspicion level: low|medium|high|critical") var minLevel: String?
    @Option(name: .long, help: "Limit number of suspects") var max: Int?
    @Flag(name: .shortAndLong, help: "Output JSON instead of text") var json: Bool = false
    mutating func run() throws { CLI.showSuspects(minLevel: minLevel, max: max, json: json) }
}

struct IO: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show top disk I/O processes")
    @Option(name: .customLong("sample-ms"), help: "Sampling duration in milliseconds") var sampleMs: Int = 600
    @Option(name: .customLong("min-mem-mb"), help: "Minimum process memory to include (MB)") var minMemMB: Double = 10
    @Option(name: .long, help: "Number of processes to show") var top: Int = 10
    @Option(name: .long, help: "Sort by 'write' or 'read' (display both)") var sort: String = "write"
    mutating func run() throws { CLI.showIO(sampleMs: sampleMs, minMemMB: minMemMB, topN: top, sortBy: sort) }
}

struct DanglingFiles: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find deleted but open files")
    mutating func run() throws { CLI.findDanglingFiles() }
}

struct Ports: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show processes on port range")
    @Argument(help: "Port range like 3000-3010") var range: String
    mutating func run() throws { CLI.showPortQuery(arguments: ["--ports", range]) }
}

struct CheckPort: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check if a specific port is available")
    @Argument(help: "Port number") var port: Int
    mutating func run() throws { CLI.checkPort(arguments: ["--check-port", String(port)]) }
}

struct FindFreePort: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find free ports in range")
    @Argument(help: "Range like 8000-9000") var range: String
    @Argument(help: "Count to find", transform: { Int($0) ?? 1 }) var count: Int = 1
    mutating func run() throws { CLI.findFreePorts(arguments: ["--find-free-port", range, String(count)]) }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Safely terminate process (SIGTERM)")
    @Argument(help: "PID") var pid: Int
    mutating func run() throws { CLI.killProcess(arguments: ["--kill", String(pid)], force: false) }
}

struct ForceKill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Force kill process (SIGKILL)")
    @Argument(help: "PID") var pid: Int
    mutating func run() throws { CLI.killProcess(arguments: ["--force-kill", String(pid)], force: true) }
}

struct KillPattern: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Kill all processes matching regex pattern")
    @Argument(help: "Regex pattern") var pattern: String
    @Flag(help: "Force kill (SIGKILL)") var force: Bool = false
    mutating func run() throws {
        var args = ["--kill-pattern", pattern]
        if force { args.append("--force") }
        CLI.killProcessPattern(arguments: args)
    }
}

struct InteractiveKill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive multi-process kill")
    @Option(help: "Port range like 3000-3010") var ports: String?
    mutating func run() throws {
        var args = ["--interactive-kill"]
        if let r = ports { args += ["--ports", r] }
        CLI.interactiveKill(arguments: args)
    }
}

struct HelpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show detailed help")
    mutating func run() throws { CLI.showHelp() }
}

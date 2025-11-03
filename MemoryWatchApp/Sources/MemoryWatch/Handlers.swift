import Foundation

enum CLI {

    static func showSnapshot(json: Bool = false, minMemMB: Double = 50, topN: Int = 15) {
        let metrics = SystemMetrics.current()
        let processes = ProcessCollector.getAllProcesses(minMemoryMB: minMemMB)
        if json {
            struct SnapshotOut: Codable {
                struct System: Codable { let totalGB: Double; let usedGB: Double; let freeGB: Double; let freePercent: Double; let pressure: String; let swapUsedMB: Double; let swapTotalMB: Double; let swapFreePercent: Double }
                struct Proc: Codable { let pid: Int32; let name: String; let memoryMB: Double; let percentMemory: Double }
                let system: System
                let processes: [Proc]
                let generatedAt: Date
            }
            let sys = SnapshotOut.System(totalGB: metrics.totalMemoryGB, usedGB: metrics.usedMemoryGB, freeGB: metrics.freeMemoryGB, freePercent: metrics.freePercent, pressure: metrics.pressure, swapUsedMB: metrics.swapUsedMB, swapTotalMB: metrics.swapTotalMB, swapFreePercent: metrics.swapFreePercent)
            let procs = processes.prefix(topN).map { SnapshotOut.Proc(pid: $0.pid, name: $0.name, memoryMB: $0.memoryMB, percentMemory: $0.percentMemory) }
            let out = SnapshotOut(system: sys, processes: procs, generatedAt: Date())
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(out), let s = String(data: data, encoding: .utf8) { print(s) }
            return
        } else {
            print("MemoryWatch - macOS Memory Monitor")
            print("===================================")
            print("")

            print("System Memory:")
            print("  Total:    \(String(format: "%6.1f", metrics.totalMemoryGB)) GB")
            print("  Used:     \(String(format: "%6.1f", metrics.usedMemoryGB)) GB")
            print("  Free:     \(String(format: "%6.1f", metrics.freeMemoryGB)) GB (\(String(format: "%.1f", metrics.freePercent))%)")
            print("  Pressure: \(pressureIcon(metrics.pressure)) \(metrics.pressure)")
            print("")

            print("Swap Usage:")
            print("  Used:  \(String(format: "%6.0f", metrics.swapUsedMB)) MB")
            print("  Total: \(String(format: "%6.0f", metrics.swapTotalMB)) MB")
            if metrics.swapTotalMB > 0 {
                print("  Free:  \(String(format: "%6.1f", metrics.swapFreePercent))%")

                if metrics.swapUsedMB > 1024 {
                    print("  ⚠️  High swap usage detected!")
                }
            }
            print("")

            print("Top Memory Consumers:")
            print("  PID     Memory      %Mem   Process")
            print("  ────────────────────────────────────")
            for process in processes.prefix(topN) {
                let pidStr = String(format: "%5d", process.pid)
                let memStr = String(format: "%6.0f MB", process.memoryMB)
                let pctStr = String(format: "%5.1f%%", process.percentMemory)
                print("  \(pidStr)  \(memStr)  \(pctStr)   \(process.name)")
            }
            print("")
            print("Usage: memwatch daemon            Start continuous monitoring")
            print("       memwatch io                Show top disk I/O processes")
            print("       memwatch dangling-files    Find deleted but open files")
            print("       memwatch report            Show leak detection report")
            print("       memwatch suspects          List leak suspects")
            print("       memwatch status            View datastore health & retention")
            print("       memwatch diagnostics PID  Collect runtime diagnostics for PID")
        }
    }

    nonisolated(unsafe) static var globalMonitor: ProcessMonitor?
    nonisolated(unsafe) static var globalStateFile: URL?

    static func runDaemon(interval: TimeInterval = 30,
                          minMemMB: Double = 50,
                          swapWarnMB: Double = 1024,
                          pageoutsWarnRate: Double = 100,
                          autosaveEvery: Int = 10,
                          reportEvery: Int = 120) {
        print("🔍 MemoryWatch Daemon Starting...")
        print("Press Ctrl+C to stop")
        print("")

        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()

        let store = try? SQLiteStore(url: MemoryWatchPaths.databaseFile)
        let monitor = ProcessMonitor(store: store)
        let stateFile = MemoryWatchPaths.stateFile

        // Store globally for signal handler
        globalMonitor = monitor
        globalStateFile = stateFile

        // Try to load previous state
        try? monitor.loadState(from: stateFile)

        var iteration = 0

        // Handle Ctrl+C gracefully
        signal(SIGINT) { _ in
            if let monitor = CLI.globalMonitor, let stateFile = CLI.globalStateFile {
                print("\n\n📊 Generating final report...")
                print(monitor.generateReport())
                print("\nSaving state...")
                try? monitor.saveState(to: stateFile)
                print("✅ MemoryWatch stopped")
            }
            exit(0)
        }

        var lastVM: (pageins: UInt64, pageouts: UInt64, ts: TimeInterval)? = nil

        while true {
            iteration += 1
            let sampleDate = Date()

            // Collect metrics
            let metrics = SystemMetrics.current()
            let processes = ProcessCollector.getAllProcessesWithCPU(minMemoryMB: minMemMB)

            // Record snapshot
            monitor.recordSnapshot(processes: processes, metrics: metrics, timestamp: sampleDate)

            // Display status
            let suspects = monitor.getLeakSuspects(minLevel: .medium)
            let alerts = monitor.getRecentAlerts(count: 5)

            let timestamp = formatTimestamp(sampleDate)

            print("[\(timestamp)] Scan #\(iteration)")
            print("  Memory: \(String(format: "%.1f", metrics.usedMemoryGB))/\(String(format: "%.1f", metrics.totalMemoryGB))GB  Swap: \(String(format: "%.0f", metrics.swapUsedMB))MB  Pressure: \(metrics.pressure)")
            print("  Processes: \(processes.count)  Suspects: \(suspects.count)  Alerts: \(alerts.count)")

            if !suspects.isEmpty {
                print("  🚨 Top Suspect: \(suspects[0].name) (+\(String(format: "%.0f", suspects[0].growthMB))MB, \(String(format: "%.1f", suspects[0].growthRate))MB/hr)")
            }

            print("")

            // Check for critical issues
            if metrics.swapUsedMB > swapWarnMB {
                print("  ⚠️  WARNING: High swap usage (\(String(format: "%.0f", metrics.swapUsedMB))MB)")
            }

            if metrics.pressure == "Critical" {
                print("  🔴 CRITICAL: Memory pressure critical!")
            }

            // VM activity (pageouts rate indicates swap pressure)
            let vm = SystemMetrics.getVMActivity()
            let now = Date().timeIntervalSince1970
            if let last = lastVM {
                let dt = now - last.ts
                if dt > 0 {
                    let pageoutsPerSec = Double(vm.pageouts &- last.pageouts) / dt
                    if pageoutsPerSec > pageoutsWarnRate { // threshold
                        print("  ⚠️  High pageouts: \(String(format: "%.0f", pageoutsPerSec))/s (swap thrashing)")
                    }
                }
            }
            lastVM = (vm.pageins, vm.pageouts, now)

            // Save state periodically
            if autosaveEvery > 0 && iteration % autosaveEvery == 0 {
                try? monitor.saveState(to: stateFile)
            }

            // Show report periodically
            if reportEvery > 0 && iteration % reportEvery == 0 {
                print("\n" + monitor.generateReport())
            }

            let sleepSec = interval > 0 ? UInt32(interval) : 1
            sleep(sleepSec)
        }
    }

    static func showIO(sampleMs: Int = 600, minMemMB: Double = 10, topN: Int = 10, sortBy: String = "write") {
        print("MemoryWatch - Disk I/O Activity")
        print("===================================")
        print("Sampling processes for I/O rates...")
        // Prime trackers
        _ = ProcessCollector.getAllProcessesWithCPU(minMemoryMB: 0)
        usleep(useconds_t(max(sampleMs, 100) * 1000))
        let processes = ProcessCollector.getAllProcessesWithCPU(minMemoryMB: minMemMB)

        let topWriters = processes.sorted { $0.ioWriteBps > $1.ioWriteBps }.prefix(topN)
        let topReaders = processes.sorted { $0.ioReadBps > $1.ioReadBps }.prefix(topN)

        func prettyBps(_ bps: Double) -> String {
            if bps >= 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024*1024)) }
            if bps >= 1024 { return String(format: "%.1f KB/s", bps / 1024) }
            return String(format: "%.0f B/s", bps)
        }

        print("")
        print("Top Disk Writers:")
        print("  PID     Write/s     CPU    Process")
        print("  ─────────────────────────────────────────")
        for p in topWriters where p.ioWriteBps > 0 {
            let pidStr = String(format: "%5d", p.pid)
            let wStr = prettyBps(p.ioWriteBps)
            let cpuStr = String(format: "%5.1f%%", p.cpuPercent)
            print("  \(pidStr)  \(String(format: "%12s", (wStr as NSString).utf8String!))  \(cpuStr)  \(p.name)")
        }

        print("")
        print("Top Disk Readers:")
        print("  PID     Read/s      CPU    Process")
        print("  ─────────────────────────────────────────")
        for p in topReaders where p.ioReadBps > 0 {
            let pidStr = String(format: "%5d", p.pid)
            let rStr = prettyBps(p.ioReadBps)
            let cpuStr = String(format: "%5.1f%%", p.cpuPercent)
            print("  \(pidStr)  \(String(format: "%12s", (rStr as NSString).utf8String!))  \(cpuStr)  \(p.name)")
        }

        print("")
        print("💡 Tip: heavy sustained writes can indicate log or cache issues.")
        if sortBy.lowercased() == "read" {
            // If user wants only readers, show readers first
        }
    }

    static func findDanglingFiles() {
        print("MemoryWatch - Deleted But Open Files")
        print("===================================")
        print("Scanning for open, unlinked files (can hold disk space)...")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "+L1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n").filter { $0.contains("(deleted)") || $0.contains("(unlinked)") || $0.contains("linkcount") }
                if lines.isEmpty {
                    print("✅ No deleted-but-open files found.")
                } else {
                    print("Found potential space holders:")
                    for line in lines { print("  \(line)") }
                    print("")
                    print("These files still occupy disk space until the process closes them.")
                }
            }
        } catch {
            print("❌ Failed to run lsof. Ensure /usr/sbin/lsof is available.")
        }
    }

    static func showReport(json: Bool = false, minLevel: String? = nil, recentAlerts: Int = 10) {
        let stateFile = MemoryWatchPaths.stateFile

        let monitor = ProcessMonitor()

        do {
            try monitor.loadState(from: stateFile)
            if json {
                let level: LeakSuspect.SuspicionLevel
                switch (minLevel ?? "").lowercased() {
                case "critical": level = .critical
                case "high": level = .high
                case "medium": level = .medium
                default: level = .medium
                }
                print(monitor.generateJSONReport(minLevel: level, recentAlertCount: recentAlerts))
            } else {
                print(monitor.generateReport())
            }
        } catch {
            print("❌ No monitoring data found. Run 'memwatch --daemon' first.")
            print("   Error: \(error.localizedDescription)")
        }
    }

    static func showStatus() {
        print("MemoryWatch Status")
        print("===================================")

        let metrics = SystemMetrics.current()

        print("System Memory:")
        print("  Total:    \(String(format: "%6.1f", metrics.totalMemoryGB)) GB")
        print("  Used:     \(String(format: "%6.1f", metrics.usedMemoryGB)) GB")
        print("  Free:     \(String(format: "%6.1f", metrics.freeMemoryGB)) GB (\(String(format: "%6.1f", metrics.freePercent))%)")
        print("  Swap:     \(String(format: "%6.0f", metrics.swapUsedMB)) / \(String(format: "%6.0f", metrics.swapTotalMB)) MB")
        print("  Pressure: \(pressureIcon(metrics.pressure)) \(metrics.pressure)")
        print("")

        let preferences = NotificationPreferencesStore.loadSync()
        print("Notifications:")
        if let desc = preferences.quietHoursDescription() {
            let policy = preferences.allowInterruptionsDuringQuietHours ? "deliver during quiet hours" : "hold during quiet hours"
            print("  Quiet hours: \(desc) (\(policy))")
        } else {
            print("  Quiet hours: disabled")
        }
        print("  Leak alerts: \(preferences.leakNotificationsEnabled ? "enabled" : "disabled")")
        print("  Pressure alerts: \(preferences.pressureNotificationsEnabled ? "enabled" : "disabled")")
        print("")

        let dbURL = MemoryWatchPaths.databaseFile
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: dbURL.path) else {
            print("Datastore:")
            print("  Path: \(dbURL.path)")
            print("  Status: Initialising (no samples recorded yet)")
            return
        }

        do {
            let store = try SQLiteStore(url: dbURL)
            let health = store.healthSnapshot()

            print("Datastore:")
            print("  Path:           \(dbURL.path)")
            print("  Schema:         v\(health.schemaVersion) (user_version=\(health.userVersion))")
            print("  Snapshots:      \(health.snapshotCount)")
            print("  Process samples:\(health.processSampleCount)")
            print("  Alerts:         \(health.alertCount)")
            if let oldest = health.oldestSnapshot {
                print("  Oldest sample:  \(formatDateTime(oldest))")
            }
            if let newest = health.newestSnapshot {
                print("  Latest sample:  \(formatDateTime(newest))")
            }
            let retentionDays = health.retentionWindowHours / 24.0
            print("  Retention:      \(String(format: "%.0f", health.retentionWindowHours)) hours (~\(String(format: "%.1f", retentionDays)) days)")

            print("  Size:           \(formatBytes(health.databaseSizeBytes)) (WAL: \(formatBytes(health.walSizeBytes)))")
            print("  Pages:          \(health.pageCount) total / \(health.freePageCount) free")

            if let maintenance = health.lastMaintenance {
                print("  Last cleanup:   \(formatDateTime(maintenance))")
            } else {
                print("  Last cleanup:   Pending (not yet run)")
            }

            print("  Integrity:      \(health.quickCheckPassed ? "OK" : "Check failed - run VACUUM")")

        } catch {
            print("Datastore:")
            print("  Path: \(dbURL.path)")
            print("  Status: Unable to open (\(error.localizedDescription))")
        }
    }

    static func showSuspects(minLevel: String? = nil, max: Int? = nil, json: Bool = false) {
        let stateFile = MemoryWatchPaths.stateFile

        let monitor = ProcessMonitor()

        do {
            try monitor.loadState(from: stateFile)
            let level: LeakSuspect.SuspicionLevel
            switch (minLevel ?? "").lowercased() {
            case "critical": level = .critical
            case "high": level = .high
            case "medium": level = .medium
            default: level = .low
            }
            var suspects = monitor.getLeakSuspects(minLevel: level)
            if let m = max, m > 0 { suspects = Array(suspects.prefix(m)) }

            if json {
                struct Out: Codable {
                    struct S: Codable {
                        let pid: Int32; let name: String
                        let initialMemoryMB: Double; let currentMemoryMB: Double
                        let growthMB: Double; let growthRate: Double
                        let firstSeen: Date; let lastSeen: Date
                        let level: String; let durationSeconds: Double
                    }
                    let suspects: [S]
                    let generatedAt: Date
                }
                let arr = suspects.map { s in
                    Out.S(pid: s.pid, name: s.name, initialMemoryMB: s.initialMemoryMB, currentMemoryMB: s.currentMemoryMB, growthMB: s.growthMB, growthRate: s.growthRate, firstSeen: s.firstSeen, lastSeen: s.lastSeen, level: s.suspicionLevel.rawValue, durationSeconds: s.lastSeen.timeIntervalSince(s.firstSeen))
                }
                let out = Out(suspects: arr, generatedAt: Date())
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
                if let data = try? enc.encode(out), let s = String(data: data, encoding: .utf8) { print(s) }
            } else {
                if suspects.isEmpty {
                    print("✅ No leak suspects found")
                    return
                }

                print("Memory Leak Suspects")
                print("═══════════════════════════════════════════════════════════")
                print("")

                for (index, suspect) in suspects.enumerated() {
                    let icon = iconForLevel(suspect.suspicionLevel)
                    print("\(index + 1). \(icon) \(suspect.name) (PID \(suspect.pid))")
                    print("   Level:    \(suspect.suspicionLevel.rawValue)")
                    print("   Growth:   \(String(format: "%.0f", suspect.initialMemoryMB))MB → \(String(format: "%.0f", suspect.currentMemoryMB))MB (+\(String(format: "%.0f", suspect.growthMB))MB)")
                    print("   Rate:     \(String(format: "%.1f", suspect.growthRate)) MB/hour")
                    print("   Duration: \(formatDuration(suspect.lastSeen.timeIntervalSince(suspect.firstSeen)))")

                    if let trend = monitor.getProcessTrend(pid: suspect.pid) {
                        print("   Trend:    \(trend)")
                    }
                    print("")
                }
            }
        } catch {
            print("❌ No monitoring data found. Run 'memwatch --daemon' first.")
        }
    }

    static func showPortQuery(arguments: [String]) {
        // Parse port range from arguments
        // Format: --ports 3000-3010 or --ports 3000 3010
        guard let portsIndex = arguments.firstIndex(where: { $0 == "--ports" || $0 == "-p" }) else {
            print("❌ Error: --ports flag found but no range specified")
            print("Usage: memwatch --ports START-END")
            print("Example: memwatch --ports 3000-3010")
            return
        }

        guard arguments.count > portsIndex + 1 else {
            print("❌ Error: Port range required")
            print("Usage: memwatch --ports START-END")
            print("Example: memwatch --ports 3000-3010")
            return
        }

        let rangeArg = arguments[portsIndex + 1]
        let parts = rangeArg.split(separator: "-")

        guard parts.count == 2,
              let startPort = Int32(parts[0]),
              let endPort = Int32(parts[1]),
              startPort <= endPort else {
            print("❌ Error: Invalid port range '\(rangeArg)'")
            print("Usage: memwatch --ports START-END")
            print("Example: memwatch --ports 3000-3010")
            return
        }

        print("MemoryWatch - Port Query")
        print("===================================")
        print("Searching for processes on ports \(startPort)-\(endPort)...")
        print("")

        let processes = PortCollector.getProcessesOnPorts(portRange: startPort...endPort)

        if processes.isEmpty {
            print("✅ No processes found listening on ports \(startPort)-\(endPort)")
            return
        }

        print("Found \(processes.count) process(es):")
        print("")
        print("  PID     Memory     CPU    %Mem   Process")
        print("  ───────────────────────────────────────────────────────")

        for process in processes {
            print("  \(process.description)")
        }

        print("")
        print("💡 Tip: Use --kill <PID> to safely terminate a process")
        print("       Use --force-kill <PID> for forceful termination")
    }

    static func killProcess(arguments: [String], force: Bool) {
        let flag = force ? "--force-kill" : "--kill"
        let shortFlag = force ? "-f" : "-k"

        guard let killIndex = arguments.firstIndex(where: { $0 == flag || $0 == shortFlag }) else {
            print("❌ Error: \(flag) flag found but no PID specified")
            print("Usage: memwatch \(flag) <PID>")
            return
        }

        guard arguments.count > killIndex + 1 else {
            print("❌ Error: PID required")
            print("Usage: memwatch \(flag) <PID>")
            return
        }

        guard let pid = Int32(arguments[killIndex + 1]) else {
            print("❌ Error: Invalid PID '\(arguments[killIndex + 1])'")
            print("Usage: memwatch \(flag) <PID>")
            return
        }

        // Check if process exists
        guard ProcessManager.isProcessRunning(pid: pid) else {
            print("❌ Process \(pid) not found or already terminated")
            return
        }

        // Get process info before killing
        if let info = ProcessCollector.getProcessInfo(pid: pid) {
            print("\(force ? "🔴" : "⚠️")  About to \(force ? "force kill" : "terminate") process:")
            print("   PID:    \(info.pid)")
            print("   Name:   \(info.name)")
            print("   Memory: \(String(format: "%.1f", info.memoryMB)) MB")
            print("")

            if !force {
                print("This will send SIGTERM (graceful shutdown)")
            } else {
                print("⚠️  WARNING: This will send SIGKILL (immediate termination)")
                print("    The process will NOT have a chance to clean up!")
            }
            print("")
            print("Continue? (y/N): ", terminator: "")

            if let response = readLine()?.lowercased(), response == "y" || response == "yes" {
                let mode: ProcessManager.KillMode = force ? .force : .safe
                let result = ProcessManager.killProcess(pid: pid, mode: mode)
                print(result.message)

                if result.success {
                    // Wait a bit and check if process is still running
                    sleep(1)
                    if ProcessManager.isProcessRunning(pid: pid) {
                        print("⚠️  Process may still be shutting down...")
                        if !force {
                            print("💡 Tip: Use --force-kill \(pid) if the process won't terminate")
                        }
                    } else {
                        print("✅ Process terminated successfully")
                    }
                }
            } else {
                print("❌ Cancelled")
            }
        } else {
            print("❌ Unable to get process information for PID \(pid)")
        }
    }

    static func checkPort(arguments: [String]) {
        guard let checkIndex = arguments.firstIndex(of: "--check-port"),
              arguments.count > checkIndex + 1,
              let port = Int32(arguments[checkIndex + 1]) else {
            print("❌ Error: Port number required")
            print("Usage: memwatch --check-port <PORT>")
            print("Example: memwatch --check-port 3000")
            return
        }

        print("MemoryWatch - Port Conflict Detection")
        print("===================================")
        print("Checking port \(port)...")
        print("")

        guard let portInfo = PortManager.checkPort(port) else {
            print("❌ Failed to check port \(port)")
            return
        }

        if portInfo.isAvailable {
            print("✅ Port \(port) is AVAILABLE")
            print("")
            print("You can safely use this port for your application.")
        } else {
            let criticalityIcon = criticalityIcon(portInfo.criticality)
            print("\(criticalityIcon) Port \(port) is IN USE")
            print("")
            print("Process Details:")
            print("  PID:          \(portInfo.pid)")
            print("  Name:         \(portInfo.processName)")
            print("  Criticality:  \(criticalityDescription(portInfo.criticality))")
            print("")

            switch portInfo.criticality {
            case .critical:
                print("🛑 CRITICAL WARNING!")
                print("   This port is used by a CRITICAL SYSTEM PROCESS!")
                print("   DO NOT attempt to kill this process.")
                print("   Doing so may crash your system or cause data loss.")
            case .systemImportant:
                print("⚠️  WARNING!")
                print("   This port is used by an important system service.")
                print("   Killing this process may affect system functionality.")
                print("   Proceed with caution.")
            case .normal:
                print("💡 Tip: Use --kill \(portInfo.pid) to terminate this process")
            }
        }
    }

    static func findFreePorts(arguments: [String]) {
        guard let findIndex = arguments.firstIndex(of: "--find-free-port") else {
            print("❌ Error: --find-free-port flag not found")
            return
        }

        // Parse port range and optional count
        var startPort: Int32 = 3000
        var endPort: Int32 = 9000
        var count = 1

        if arguments.count > findIndex + 1 {
            let rangeArg = arguments[findIndex + 1]
            if let dashIndex = rangeArg.firstIndex(of: "-") {
                let start = String(rangeArg[..<dashIndex])
                let end = String(rangeArg[rangeArg.index(after: dashIndex)...])
                startPort = Int32(start) ?? 3000
                endPort = Int32(end) ?? 9000
            } else if let port = Int32(rangeArg) {
                startPort = port
                endPort = port + 1000
            }
        }

        if arguments.count > findIndex + 2, let c = Int(arguments[findIndex + 2]) {
            count = c
        }

        print("MemoryWatch - Find Free Ports")
        print("===================================")
        print("Searching for \(count) free port(s) in range \(startPort)-\(endPort)...")
        print("")

        let freePorts = PortManager.findFreePorts(in: startPort...endPort, count: count)

        if freePorts.isEmpty {
            print("❌ No free ports found in range \(startPort)-\(endPort)")
            print("")
            print("💡 Try a different port range or close some applications")
        } else {
            print("✅ Found \(freePorts.count) free port(s):")
            for port in freePorts {
                print("   • \(port)")
            }
            print("")
            print("These ports are ready to use!")
        }
    }

    static func killProcessPattern(arguments: [String]) {
        guard let patternIndex = arguments.firstIndex(of: "--kill-pattern"),
              arguments.count > patternIndex + 1 else {
            print("❌ Error: Process name pattern required")
            print("Usage: memwatch --kill-pattern <PATTERN>")
            print("Example: memwatch --kill-pattern \"node.*3000\"")
            return
        }

        let pattern = arguments[patternIndex + 1]
        let force = arguments.contains("--force")

        print("MemoryWatch - Process Group Management")
        print("===================================")
        print("Searching for processes matching: \(pattern)")
        print("")

        // Preview matching processes
        let allProcesses = ProcessCollector.getAllProcessesWithCPU(minMemoryMB: 0)
        let matchingProcesses = allProcesses.filter { process in
            process.name.range(of: pattern, options: .regularExpression) != nil
        }

        if matchingProcesses.isEmpty {
            print("✅ No processes found matching pattern: \(pattern)")
            return
        }

        print("Found \(matchingProcesses.count) matching process(es):")
        print("")

        var criticalCount = 0
        var importantCount = 0
        var normalCount = 0

        for process in matchingProcesses {
            let criticality = ProcessManager.assessCriticality(processName: process.name, pid: process.pid)
            let icon = criticalityIcon(criticality)
            print("  \(icon) PID \(process.pid): \(process.name) (\(String(format: "%.1f", process.memoryMB)) MB)")

            switch criticality {
            case .critical: criticalCount += 1
            case .systemImportant: importantCount += 1
            case .normal: normalCount += 1
            }
        }

        print("")

        if criticalCount > 0 {
            print("🛑 CRITICAL WARNING!")
            print("   \(criticalCount) CRITICAL SYSTEM PROCESS(ES) will be SKIPPED!")
            print("   These processes are essential to your system.")
            print("")
        }

        if importantCount > 0 {
            print("⚠️  WARNING!")
            print("   \(importantCount) important system service(s) found.")
            print("   Killing these may affect system functionality.")
            print("")
        }

        print("This will \(force ? "FORCE KILL" : "terminate") \(normalCount + importantCount) process(es).")
        print("")
        print("Continue? (y/N): ", terminator: "")

        if let response = readLine()?.lowercased(), response == "y" || response == "yes" {
            let mode: ProcessManager.KillMode = force ? .force : .safe
            let results = ProcessManager.killProcessGroup(pattern: pattern, mode: mode)

            print("")
            print("Results:")
            print("────────────────────────────────")

            for result in results {
                let icon = result.success ? "✅" : "❌"
                print("\(icon) PID \(result.pid) (\(result.name)): \(result.message)")
            }

            let successCount = results.filter { $0.success }.count
            print("")
            print("Terminated \(successCount)/\(results.count) processes")
        } else {
            print("❌ Cancelled")
        }
    }

    static func interactiveKill(arguments: [String]) {
        // Parse optional port range
        var portRange: ClosedRange<Int32>?

        if let portsIndex = arguments.firstIndex(where: { $0 == "--ports" || $0 == "-p" }),
           arguments.count > portsIndex + 1 {
            let rangeArg = arguments[portsIndex + 1]
            let parts = rangeArg.split(separator: "-")

            if parts.count == 2,
               let startPort = Int32(parts[0]),
               let endPort = Int32(parts[1]),
               startPort <= endPort {
                portRange = startPort...endPort
            }
        }

        print("MemoryWatch - Interactive Multi-Kill")
        print("===================================")

        let processes: [ProcessInfo]
        if let range = portRange {
            print("Showing processes on ports \(range.lowerBound)-\(range.upperBound)...")
            processes = PortCollector.getProcessesOnPorts(portRange: range)
        } else {
            print("Showing all processes (>50MB memory)...")
            processes = ProcessCollector.getAllProcessesWithCPU(minMemoryMB: 50)
        }

        if processes.isEmpty {
            print("")
            print("✅ No processes found")
            return
        }

        print("")
        print("Found \(processes.count) process(es):")
        print("")
        print("  #   PID     Memory     CPU    Process")
        print("  ───────────────────────────────────────────────────────")

        for (index, process) in processes.enumerated() {
            let criticality = ProcessManager.assessCriticality(processName: process.name, pid: process.pid)
            let icon = criticalityIcon(criticality)
            let indexStr = String(format: "%2d", index + 1)
            let pidStr = String(format: "%5d", process.pid)
            let memStr = String(format: "%7.1f MB", process.memoryMB)
            let cpuStr = String(format: "%5.1f%%", process.cpuPercent)
            let portsStr = process.ports.isEmpty ? "" : " [Ports: \(process.ports.map(String.init).joined(separator: ", "))]"

            print("  \(indexStr)  \(pidStr)  \(memStr)  \(cpuStr)  \(icon) \(process.name)\(portsStr)")
        }

        print("")
        print("Enter process numbers to kill (comma-separated, e.g., 1,3,5)")
        print("Or enter 'all' to kill all non-critical processes")
        print("Or enter 'cancel' to abort")
        print("")
        print("> ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            print("❌ Cancelled")
            return
        }

        if input == "cancel" || input.isEmpty {
            print("❌ Cancelled")
            return
        }

        var selectedIndices: [Int] = []

        if input == "all" {
            selectedIndices = Array(0..<processes.count)
        } else {
            let parts = input.split(separator: ",")
            for part in parts {
                if let num = Int(part.trimmingCharacters(in: .whitespaces)), num > 0, num <= processes.count {
                    selectedIndices.append(num - 1)
                }
            }
        }

        if selectedIndices.isEmpty {
            print("❌ No valid processes selected")
            return
        }

        print("")
        print("Selected \(selectedIndices.count) process(es) to kill:")
        print("")

        var criticalCount = 0
        var importantCount = 0
        var normalCount = 0

        for index in selectedIndices {
            let process = processes[index]
            let criticality = ProcessManager.assessCriticality(processName: process.name, pid: process.pid)
            let icon = criticalityIcon(criticality)

            print("  \(icon) PID \(process.pid): \(process.name)")

            switch criticality {
            case .critical: criticalCount += 1
            case .systemImportant: importantCount += 1
            case .normal: normalCount += 1
            }
        }

        print("")

        if criticalCount > 0 {
            print("🛑 CRITICAL WARNING!")
            print("   \(criticalCount) CRITICAL SYSTEM PROCESS(ES) will be SKIPPED!")
            print("   These processes are essential to your system.")
            print("")
        }

        if importantCount > 0 {
            print("⚠️  WARNING!")
            print("   \(importantCount) important system service(s) selected.")
            print("   Killing these may affect system functionality.")
            print("")
        }

        print("Kill \(normalCount + importantCount) process(es)? (y/N): ", terminator: "")

        if let response = readLine()?.lowercased(), response == "y" || response == "yes" {
            print("")
            print("Terminating processes...")
            print("")

            var successCount = 0

            for index in selectedIndices {
                let process = processes[index]
                let criticality = ProcessManager.assessCriticality(processName: process.name, pid: process.pid)

                if criticality == .critical {
                    print("⏭️  PID \(process.pid) (\(process.name)): SKIPPED (critical system process)")
                    continue
                }

                let result = ProcessManager.killProcess(pid: process.pid, mode: .safe)
                print("\(result.success ? "✅" : "❌") PID \(process.pid) (\(process.name)): \(result.message)")

                if result.success {
                    successCount += 1
                }
            }

            print("")
            print("Terminated \(successCount)/\(selectedIndices.count) processes")
        } else {
            print("❌ Cancelled")
        }
    }

    static func showHelp() {
        print("""
        MemoryWatch - macOS Memory Monitoring & Leak Detection

        USAGE:
            memwatch [OPTIONS]

        OPTIONS:
            (no args)              Show current memory snapshot
            --daemon, -d           Run continuous monitoring daemon
            --io                   Show top disk I/O processes
            --dangling-files       Find deleted-but-open files
            --report, -r           Display leak detection report
            --suspects, -s         List all memory leak suspects
            --ports, -p START-END  Show processes on port range
            --check-port PORT      Check if a specific port is available
            --find-free-port RANGE [COUNT]  Find free ports in range
            --kill-pattern PATTERN Kill processes matching pattern
            --interactive-kill, -i Interactive multi-process kill
            --kill, -k PID         Safely terminate process (SIGTERM)
            --force-kill, -f PID   Force kill process (SIGKILL)
            --help, -h             Show this help message

        EXAMPLES:
            # Quick snapshot
            memwatch

            # Start continuous monitoring
            memwatch --daemon

            # Check for leaks
            memwatch --suspects

            # View full report
            memwatch --report

            # Find processes on ports 3000-3010
            memwatch --ports 3000-3010

            # Check if port 3000 is available
            memwatch --check-port 3000

            # Find 3 free ports in range 8000-9000
            memwatch --find-free-port 8000-9000 3

            # Kill all node processes
            memwatch --kill-pattern "node"

            # Interactive kill for port range
            memwatch --interactive-kill --ports 3000-3010

            # Interactive kill for all processes
            memwatch --interactive-kill

            # Safely terminate a process
            memwatch --kill 1234

            # Force kill a stubborn process
            memwatch --force-kill 1234

        PORT MANAGEMENT:
            --check-port:      Check if specific port is available
                              Shows process details if port is in use
                              Displays criticality warnings

            --find-free-port:  Find available ports in range
                              Useful before starting new services

            --ports:           Query processes on port range
                              Displays memory, CPU, and port info

        PROCESS MANAGEMENT:
            --kill:            Sends SIGTERM (graceful shutdown)
                              Process can clean up resources
                              Recommended for normal termination

            --force-kill:      Sends SIGKILL (immediate termination)
                              Process cannot clean up
                              Use only when --kill fails

            --kill-pattern:    Kill all processes matching regex pattern
                              Skips critical system processes
                              Requires confirmation

            --interactive-kill: Interactive multi-process kill
                               Select processes by number
                               Supports port range filtering
                               Shows criticality warnings

        PROCESS CRITICALITY LEVELS:
            🟢 Normal      - Regular user processes (safe to kill)
            🟡 Important   - System services (warn before killing)
            🛑 Critical    - Essential processes (NEVER kill)

        DAEMON MODE:
            - Monitors processes every 30 seconds
            - Detects memory leaks automatically
            - Saves state to organized directories
            - Press Ctrl+C to stop and see report

        LEAK DETECTION LEVELS:
            🟡 Low      - Minor growth (>10MB/hr)
            🟠 Medium   - Moderate growth (>50MB/hr)
            🔴 High     - Significant growth (>100MB/hr)
            🚨 Critical - Rapid growth (>100MB in single scan)

        DATA ORGANIZATION:
            ~/MemoryWatch/
            ├── data/
            │   ├── snapshots/    # CSV logs
            │   ├── state/        # Process state
            │   └── samples/      # Detailed samples
            ├── logs/
            │   ├── events/       # System events
            │   ├── leaks/        # Leak detection
            │   └── daemon/       # Daemon logs
            └── reports/
                ├── daily/        # Daily reports
                ├── weekly/       # Weekly reports
                └── on-demand/    # Manual reports

        """)
    }

    // MARK: - Helper Functions

    static func formatBytes(_ bytes: UInt64) -> String {
        let units: [String] = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024.0 && unitIndex < units.count - 1 {
            value /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 {
            return String(format: "%.0f %@", value, units[unitIndex])
        } else {
            return String(format: "%.1f %@", value, units[unitIndex])
        }
    }

    static func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func pressureIcon(_ pressure: String) -> String {
        switch pressure {
        case "Normal": return "🟢"
        case "Warning": return "🟡"
        case "Critical": return "🔴"
        default: return "⚪"
        }
    }

    static func criticalityIcon(_ criticality: ProcessManager.ProcessCriticality) -> String {
        switch criticality {
        case .critical: return "🛑"
        case .systemImportant: return "🟡"
        case .normal: return "🟢"
        }
    }

    static func criticalityDescription(_ criticality: ProcessManager.ProcessCriticality) -> String {
        switch criticality {
        case .critical: return "CRITICAL (System Essential)"
        case .systemImportant: return "IMPORTANT (System Service)"
        case .normal: return "Normal"
        }
    }

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Global Helper Functions

func iconForLevel(_ level: LeakSuspect.SuspicionLevel) -> String {
    switch level {
    case .low: return "🟡"
    case .medium: return "🟠"
    case .high: return "🔴"
    case .critical: return "🚨"
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60

    if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else if minutes > 0 {
        return "\(minutes)m"
    } else {
        return "\(Int(seconds))s"
    }
}

// Entry point moved to CLIArgumentParser.swift using ArgumentParser

import Foundation

// MARK: - Command Line Interface

struct CLI {
    static func run() {
        let arguments = CommandLine.arguments

        if arguments.contains("--daemon") || arguments.contains("-d") {
            runDaemon()
        } else if arguments.contains("--report") || arguments.contains("-r") {
            showReport()
        } else if arguments.contains("--suspects") || arguments.contains("-s") {
            showSuspects()
        } else if arguments.contains("--ports") || arguments.contains("-p") {
            showPortQuery(arguments: arguments)
        } else if arguments.contains("--kill") || arguments.contains("-k") {
            killProcess(arguments: arguments, force: false)
        } else if arguments.contains("--force-kill") || arguments.contains("-f") {
            killProcess(arguments: arguments, force: true)
        } else if arguments.contains("--help") || arguments.contains("-h") {
            showHelp()
        } else {
            showSnapshot()
        }
    }

    static func showSnapshot() {
        print("MemoryWatch - macOS Memory Monitor")
        print("===================================")
        print("")

        let metrics = SystemMetrics.current()

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

        let processes = ProcessCollector.getAllProcesses(minMemoryMB: 50)
        for process in processes.prefix(15) {
            let pidStr = String(format: "%5d", process.pid)
            let memStr = String(format: "%6.0f MB", process.memoryMB)
            let pctStr = String(format: "%5.1f%%", process.percentMemory)
            print("  \(pidStr)  \(memStr)  \(pctStr)   \(process.name)")
        }
        print("")
        print("Usage: memwatch --daemon    Start continuous monitoring")
        print("       memwatch --report    Show leak detection report")
        print("       memwatch --suspects  List leak suspects")
    }

    nonisolated(unsafe) static var globalMonitor: ProcessMonitor?
    nonisolated(unsafe) static var globalStateFile: URL?

    static func runDaemon() {
        print("🔍 MemoryWatch Daemon Starting...")
        print("Press Ctrl+C to stop")
        print("")

        let monitor = ProcessMonitor()
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MemoryWatch/memwatch_state.json")

        // Store globally for signal handler
        globalMonitor = monitor
        globalStateFile = stateFile

        // Try to load previous state
        try? monitor.loadState(from: stateFile)

        var iteration = 0
        let interval: TimeInterval = 30 // 30 seconds

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

        while true {
            iteration += 1
            let timestamp = formatTimestamp(Date())

            // Collect metrics
            let metrics = SystemMetrics.current()
            let processes = ProcessCollector.getAllProcesses(minMemoryMB: 50)

            // Record snapshot
            monitor.recordSnapshot(processes: processes)

            // Display status
            let suspects = monitor.getLeakSuspects(minLevel: .medium)
            let alerts = monitor.getRecentAlerts(count: 5)

            print("[\(timestamp)] Scan #\(iteration)")
            print("  Memory: \(String(format: "%.1f", metrics.usedMemoryGB))/\(String(format: "%.1f", metrics.totalMemoryGB))GB  Swap: \(String(format: "%.0f", metrics.swapUsedMB))MB  Pressure: \(metrics.pressure)")
            print("  Processes: \(processes.count)  Suspects: \(suspects.count)  Alerts: \(alerts.count)")

            if !suspects.isEmpty {
                print("  🚨 Top Suspect: \(suspects[0].name) (+\(String(format: "%.0f", suspects[0].growthMB))MB, \(String(format: "%.1f", suspects[0].growthRate))MB/hr)")
            }

            print("")

            // Check for critical issues
            if metrics.swapUsedMB > 1024 {
                print("  ⚠️  WARNING: High swap usage (\(String(format: "%.0f", metrics.swapUsedMB))MB)")
            }

            if metrics.pressure == "Critical" {
                print("  🔴 CRITICAL: Memory pressure critical!")
            }

            // Save state periodically (every 10 iterations)
            if iteration % 10 == 0 {
                try? monitor.saveState(to: stateFile)
            }

            // Show report every hour (120 iterations = 3600 seconds)
            if iteration % 120 == 0 {
                print("\n" + monitor.generateReport())
            }

            sleep(UInt32(interval))
        }
    }

    static func showReport() {
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MemoryWatch/memwatch_state.json")

        let monitor = ProcessMonitor()

        do {
            try monitor.loadState(from: stateFile)
            print(monitor.generateReport())
        } catch {
            print("❌ No monitoring data found. Run 'memwatch --daemon' first.")
            print("   Error: \(error.localizedDescription)")
        }
    }

    static func showSuspects() {
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MemoryWatch/memwatch_state.json")

        let monitor = ProcessMonitor()

        do {
            try monitor.loadState(from: stateFile)
            let suspects = monitor.getLeakSuspects(minLevel: .low)

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

    static func showHelp() {
        print("""
        MemoryWatch - macOS Memory Monitoring & Leak Detection

        USAGE:
            memwatch [OPTIONS]

        OPTIONS:
            (no args)              Show current memory snapshot
            --daemon, -d           Run continuous monitoring daemon
            --report, -r           Display leak detection report
            --suspects, -s         List all memory leak suspects
            --ports, -p START-END  Show processes on port range
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

            # Safely terminate a process
            memwatch --kill 1234

            # Force kill a stubborn process
            memwatch --force-kill 1234

        PORT QUERY:
            - Shows processes listening on specified port range
            - Displays memory and CPU usage for each process
            - Useful for finding dev servers (e.g., 3000-8080)

        PROCESS MANAGEMENT:
            --kill:       Sends SIGTERM (graceful shutdown)
                         Process can clean up resources
                         Recommended for normal termination

            --force-kill: Sends SIGKILL (immediate termination)
                         Process cannot clean up
                         Use only when --kill fails

        DAEMON MODE:
            - Monitors processes every 30 seconds
            - Detects memory leaks automatically
            - Saves state to ~/MemoryWatch/memwatch_state.json
            - Press Ctrl+C to stop and see report

        LEAK DETECTION LEVELS:
            🟡 Low      - Minor growth (>10MB/hr)
            🟠 Medium   - Moderate growth (>50MB/hr)
            🔴 High     - Significant growth (>100MB/hr)
            🚨 Critical - Rapid growth (>100MB in single scan)

        DATA LOCATION:
            State:   ~/MemoryWatch/memwatch_state.json
            Logs:    ~/MemoryWatch/events.log

        """)
    }

    // MARK: - Helper Functions

    static func pressureIcon(_ pressure: String) -> String {
        switch pressure {
        case "Normal": return "🟢"
        case "Warning": return "🟡"
        case "Critical": return "🔴"
        default: return "⚪"
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

// MARK: - Entry Point

CLI.run()

import Foundation

// MARK: - Command Line Interface

struct CLI {
    static func run() {
        // Initialize directories
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()

        let arguments = CommandLine.arguments

        if arguments.contains("--daemon") || arguments.contains("-d") {
            runDaemon()
        } else if arguments.contains("--report") || arguments.contains("-r") {
            showReport()
        } else if arguments.contains("--suspects") || arguments.contains("-s") {
            showSuspects()
        } else if arguments.contains("--ports") || arguments.contains("-p") {
            showPortQuery(arguments: arguments)
        } else if arguments.contains("--check-port") {
            checkPort(arguments: arguments)
        } else if arguments.contains("--find-free-port") {
            findFreePorts(arguments: arguments)
        } else if arguments.contains("--kill-pattern") {
            killProcessPattern(arguments: arguments)
        } else if arguments.contains("--interactive-kill") || arguments.contains("-i") {
            interactiveKill(arguments: arguments)
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
        let stateFile = MemoryWatchPaths.stateFile

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
        let stateFile = MemoryWatchPaths.stateFile

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
        let stateFile = MemoryWatchPaths.stateFile

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

// MARK: - Entry Point

CLI.run()

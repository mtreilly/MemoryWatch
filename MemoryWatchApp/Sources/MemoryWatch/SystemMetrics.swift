import Foundation

// MARK: - Directory Configuration

public struct MemoryWatchPaths {
    public static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MemoryWatch")

    // Data directories
    public static let dataDir = baseDir.appendingPathComponent("data")
    public static let snapshotsDir = dataDir.appendingPathComponent("snapshots")
    public static let stateDir = dataDir.appendingPathComponent("state")
    public static let samplesDir = dataDir.appendingPathComponent("samples")
    public static let databaseFile = dataDir.appendingPathComponent("memorywatch.sqlite")

    // Log directories
    public static let logsDir = baseDir.appendingPathComponent("logs")
    public static let eventsLogsDir = logsDir.appendingPathComponent("events")
    public static let leaksLogsDir = logsDir.appendingPathComponent("leaks")
    public static let daemonLogsDir = logsDir.appendingPathComponent("daemon")

    // Report directories
    public static let reportsDir = baseDir.appendingPathComponent("reports")
    public static let dailyReportsDir = reportsDir.appendingPathComponent("daily")
    public static let weeklyReportsDir = reportsDir.appendingPathComponent("weekly")
    public static let onDemandReportsDir = reportsDir.appendingPathComponent("on-demand")

    // Legacy paths (for migration)
    public static let legacyStateFile = baseDir.appendingPathComponent("memwatch_state.json")

    // Current file paths
    public static let stateFile = stateDir.appendingPathComponent("memwatch_state.json")
    public static let memoryLogFile = snapshotsDir.appendingPathComponent("memory_log.csv")
    public static let swapHistoryFile = snapshotsDir.appendingPathComponent("swap_history.csv")
    public static let eventsLogFile = eventsLogsDir.appendingPathComponent("events.log")
    public static let leaksLogFile = leaksLogsDir.appendingPathComponent("memory_leaks.log")

    public static func ensureDirectoriesExist() throws {
        let dirs = [
            dataDir, snapshotsDir, stateDir, samplesDir,
            logsDir, eventsLogsDir, leaksLogsDir, daemonLogsDir,
            reportsDir, dailyReportsDir, weeklyReportsDir, onDemandReportsDir
        ]

        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func migrateLegacyFiles() {
        // Migrate old state file if it exists
        if FileManager.default.fileExists(atPath: legacyStateFile.path) {
            try? FileManager.default.moveItem(at: legacyStateFile, to: stateFile)
        }
    }
}

public struct SystemMetrics {
    public let totalMemoryGB: Double
    public let usedMemoryGB: Double
    public let freeMemoryGB: Double
    public let freePercent: Double
    public let swapUsedMB: Double
    public let swapTotalMB: Double
    public let swapFreePercent: Double
    public let pressure: String

    public static func current() -> SystemMetrics {
        let memory = getSystemMemory()
        let swap = getSwapUsage()
        let pressure = determinePressure(freePercent: (memory.free / memory.total) * 100)

        return SystemMetrics(
            totalMemoryGB: memory.total,
            usedMemoryGB: memory.used,
            freeMemoryGB: memory.free,
            freePercent: (memory.free / memory.total) * 100,
            swapUsedMB: swap.used,
            swapTotalMB: swap.total,
            swapFreePercent: swap.total > 0 ? ((swap.total - swap.used) / swap.total) * 100 : 100,
            pressure: pressure
        )
    }

    private static func getSystemMemory() -> (total: Double, used: Double, free: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, 0, 0)
        }

        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let totalPages = Foundation.ProcessInfo.processInfo.physicalMemory / UInt64(pageSize)
        let freePages = UInt64(stats.free_count)
        let activePages = UInt64(stats.active_count)
        let wiredPages = UInt64(stats.wire_count)
        let inactivePages = UInt64(stats.inactive_count)

        let usedPages = activePages + wiredPages
        let totalGB = Double(totalPages) * pageSize / 1_073_741_824
        let usedGB = Double(usedPages) * pageSize / 1_073_741_824
        let freeGB = Double(freePages + inactivePages) * pageSize / 1_073_741_824

        return (totalGB, usedGB, freeGB)
    }

    private static func getSwapUsage() -> (used: Double, total: Double) {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        let result = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }

        let usedMB = Double(swapUsage.xsu_used) / 1_048_576
        let totalMB = Double(swapUsage.xsu_total) / 1_048_576

        return (usedMB, totalMB)
    }

    private static func determinePressure(freePercent: Double) -> String {
        if freePercent > 50 {
            return "Normal"
        } else if freePercent > 25 {
            return "Warning"
        } else {
            return "Critical"
        }
    }

    public static func getVMActivity() -> (pageins: UInt64, pageouts: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, 0)
        }
        return (UInt64(stats.pageins), UInt64(stats.pageouts))
    }
}

public struct ProcessInfo: Sendable {
    public let pid: Int32
    public let name: String
    public let executablePath: String?
    public let memoryMB: Double
    public let percentMemory: Double
    public let cpuPercent: Double
    public let ioReadBps: Double
    public let ioWriteBps: Double
    public let ports: [Int32]

    public var description: String {
        let pidStr = String(format: "%5d", pid)
        let memStr = String(format: "%7.1f MB", memoryMB)
        let cpuStr = String(format: "%5.1f%%", cpuPercent)
        var ioStr = ""
        if ioReadBps > 0 || ioWriteBps > 0 {
            func prettyBps(_ bps: Double) -> String {
                if bps >= 1024 * 1024 { return String(format: "%.1fMB/s", bps / (1024*1024)) }
                if bps >= 1024 { return String(format: "%.1fKB/s", bps / 1024) }
                return String(format: "%.0fB/s", bps)
            }
            ioStr = "  IO R/W: \(prettyBps(ioReadBps))/\(prettyBps(ioWriteBps))"
        }
        let pctStr = String(format: "%5.1f%%", percentMemory)
        let portsStr = ports.isEmpty ? "" : " [Ports: \(ports.map(String.init).joined(separator: ", "))]"
        return "\(pidStr)  \(memStr)  \(cpuStr)  \(pctStr)  \(name)\(portsStr)\(ioStr)"
    }
}

struct PortCollector {
    static func getProcessesOnPorts(portRange: ClosedRange<Int32>) -> [ProcessInfo] {
        var processMap: [Int32: [Int32]] = [:] // pid -> [ports]

        // Use lsof to get processes listening on ports in range
        let lsofTask = Process()
        lsofTask.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofTask.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]

        let pipe = Pipe()
        lsofTask.standardOutput = pipe
        lsofTask.standardError = Pipe() // Suppress errors

        do {
            try lsofTask.run()
            lsofTask.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") {
                    // Parse lsof output: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
                    let parts = line.split(separator: " ").filter { !$0.isEmpty }
                    guard parts.count >= 9 else { continue }

                    // Extract PID and port from NAME column (format: *:PORT or IP:PORT)
                    if let pid = Int32(parts[1]),
                       let portStr = parts.last?.split(separator: ":").last,
                       let port = Int32(portStr),
                       portRange.contains(port) {
                        if processMap[pid] == nil {
                            processMap[pid] = []
                        }
                        if !processMap[pid]!.contains(port) {
                            processMap[pid]!.append(port)
                        }
                    }
                }
            }
        } catch {
            // lsof failed, return empty
            return []
        }

        // Get full process info for each pid
        var processes: [ProcessInfo] = []
        for (pid, ports) in processMap {
            if let info = ProcessCollector.getProcessInfo(pid: pid) {
                processes.append(ProcessInfo(
                    pid: info.pid,
                    name: info.name,
                    executablePath: info.executablePath,
                    memoryMB: info.memoryMB,
                    percentMemory: info.percentMemory,
                    cpuPercent: info.cpuPercent,
                    ioReadBps: info.ioReadBps,
                    ioWriteBps: info.ioWriteBps,
                    ports: ports.sorted()
                ))
            }
        }

        processes.sort { $0.memoryMB > $1.memoryMB }
        return processes
    }
}

public struct ProcessCollector {
    private struct CPUSample { let totalTimeNs: UInt64; let ts: TimeInterval }
    private struct IOSample { let readBytes: UInt64; let writeBytes: UInt64; let ts: TimeInterval }
    nonisolated(unsafe) private static var cpuSamples: [Int32: CPUSample] = [:]
    nonisolated(unsafe) private static var ioSamples: [Int32: IOSample] = [:]
    private static let ncpu: Int = {
        var n: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &n, &size, nil, 0)
        return Int(n > 0 ? n : 1)
    }()

    public static func getAllProcesses(minMemoryMB: Double = 10) -> [(pid: Int32, name: String, memoryMB: Double, percentMemory: Double)] {
        var processes: [(Int32, String, Double, Double)] = []
        var pids = [pid_t](repeating: 0, count: 2048)

        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard result > 0 else { return [] }

        let processCount = Int(result) / MemoryLayout<pid_t>.size

        for i in 0..<processCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // Try to get process info using proc_pidinfo which doesn't require task_for_pid
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))

            var name: String
            if pathLen > 0 {
                let pathData = Data(bytes: pathBuf, count: pathBuf.firstIndex(of: 0) ?? pathBuf.count)
                let path = String(decoding: pathData, as: UTF8.self)
                name = path.components(separatedBy: "/").last ?? ""
            } else {
                // Fallback to process name
                var procName = proc_bsdshortinfo()
                let nameResult = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &procName, Int32(MemoryLayout<proc_bsdshortinfo>.size))
                if nameResult > 0 {
                    name = withUnsafeBytes(of: &procName.pbsi_comm) { ptr in
                        String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
                    }
                } else {
                    continue
                }
            }

            guard !name.isEmpty else { continue }

            // Use proc_pidinfo to get memory info (doesn't require task_for_pid)
            var taskInfo = proc_taskinfo()
            let infoResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))

            guard infoResult > 0 else { continue }

            let memoryBytes = taskInfo.pti_resident_size
            let memoryMB = Double(memoryBytes) / 1_048_576
            let percentMemory = (Double(memoryBytes) / Double(Foundation.ProcessInfo.processInfo.physicalMemory)) * 100

            if memoryMB >= minMemoryMB {
                processes.append((pid, name, memoryMB, percentMemory))
            }
        }

        processes.sort { $0.2 > $1.2 }
        return processes
    }

    public static func getProcessInfo(pid: Int32) -> ProcessInfo? {
        // Get process name
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))

        var name: String
        var pathString: String?
        if pathLen > 0 {
            let pathData = Data(bytes: pathBuf, count: pathBuf.firstIndex(of: 0) ?? pathBuf.count)
            let path = String(decoding: pathData, as: UTF8.self)
            pathString = path
            name = path.components(separatedBy: "/").last ?? ""
        } else {
            var procName = proc_bsdshortinfo()
            let nameResult = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &procName, Int32(MemoryLayout<proc_bsdshortinfo>.size))
            if nameResult > 0 {
                name = withUnsafeBytes(of: &procName.pbsi_comm) { ptr in
                    String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
                }
            } else {
                return nil
            }
        }

        guard !name.isEmpty else { return nil }

        // Get memory and CPU info
        var taskInfo = proc_taskinfo()
        let infoResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
        guard infoResult > 0 else { return nil }

        let memoryBytes = taskInfo.pti_resident_size
        let memoryMB = Double(memoryBytes) / 1_048_576
        let percentMemory = (Double(memoryBytes) / Double(Foundation.ProcessInfo.processInfo.physicalMemory)) * 100

        // Calculate CPU percentage based on delta over time
        let totalTimeNs: UInt64 = taskInfo.pti_total_user + taskInfo.pti_total_system
        let now = Date().timeIntervalSince1970
        var cpuPercent: Double = 0
        if let last = cpuSamples[pid] {
            let dt = now - last.ts
            if dt > 0 {
                let dNs = Double(totalTimeNs &- last.totalTimeNs)
                // percent over all cores
                cpuPercent = min(100.0, max(0.0, (dNs / 1_000_000_000.0) / dt / Double(ncpu) * 100.0))
            }
        }
        cpuSamples[pid] = CPUSample(totalTimeNs: totalTimeNs, ts: now)

        // Per-process disk IO via proc_pid_rusage
        var ri = rusage_info_current()
        var ioReadBps: Double = 0
        var ioWriteBps: Double = 0
        let r = withUnsafeMutablePointer(to: &ri) { ptr -> Int32 in
            return ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rptr in
                return proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rptr)
            }
        }
        if r == 0 {
            // Not permitted or failed; leave IO as 0
        } else {
            let readBytes = ri.ri_diskio_bytesread
            let writeBytes = ri.ri_diskio_byteswritten
            if let last = ioSamples[pid] {
                let dt = now - last.ts
                if dt > 0 {
                    let dR = Double(readBytes &- last.readBytes)
                    let dW = Double(writeBytes &- last.writeBytes)
                    ioReadBps = max(0, dR / dt)
                    ioWriteBps = max(0, dW / dt)
                }
            }
            ioSamples[pid] = IOSample(readBytes: readBytes, writeBytes: writeBytes, ts: now)
        }

        return ProcessInfo(
            pid: pid,
            name: name,
            executablePath: pathString,
            memoryMB: memoryMB,
            percentMemory: percentMemory,
            cpuPercent: cpuPercent,
            ioReadBps: ioReadBps,
            ioWriteBps: ioWriteBps,
            ports: []
        )
    }

    public static func getAllProcessesWithCPU(minMemoryMB: Double = 10) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []
        var pids = [pid_t](repeating: 0, count: 2048)

        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard result > 0 else { return [] }

        let processCount = Int(result) / MemoryLayout<pid_t>.size

        for i in 0..<processCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            if let info = getProcessInfo(pid: pid), info.memoryMB >= minMemoryMB {
                processes.append(info)
            }
        }

        processes.sort { $0.memoryMB > $1.memoryMB }
        return processes
    }
}

struct ProcessManager {
    enum KillMode {
        case safe       // SIGTERM
        case force      // SIGKILL
    }

    enum ProcessCriticality {
        case critical           // OS-critical (kernel, launchd, system daemons)
        case systemImportant    // Important system services
        case normal             // Regular user processes
    }

    // OS-critical process names (should NEVER be killed)
    private static let criticalProcessNames: Set<String> = [
        "kernel_task", "launchd", "init", "systemd",
        "WindowServer", "loginwindow", "SystemUIServer",
        "Dock", "Finder", "NotificationCenter"
    ]

    // Important system processes (warn before killing)
    private static let importantProcessNames: Set<String> = [
        "cfprefsd", "distnoted", "UserEventAgent",
        "bluetoothd", "coreaudiod", "CoreServicesUIAgent",
        "sharingd", "cloudd", "nsurlsessiond"
    ]

    static func assessCriticality(processName: String, pid: Int32) -> ProcessCriticality {
        // PID 0 and 1 are always critical
        if pid <= 1 {
            return .critical
        }

        // Check against known critical processes
        if criticalProcessNames.contains(processName) {
            return .critical
        }

        // Check against important system processes
        if importantProcessNames.contains(processName) {
            return .systemImportant
        }

        return .normal
    }

    static func killProcess(pid: Int32, mode: KillMode = .safe) -> (success: Bool, message: String) {
        let signal: Int32 = mode == .safe ? SIGTERM : SIGKILL
        let result = kill(pid, signal)

        if result == 0 {
            let modeStr = mode == .safe ? "SIGTERM" : "SIGKILL"
            return (true, "✅ Sent \(modeStr) to PID \(pid)")
        } else {
            let error = String(cString: strerror(errno))
            return (false, "❌ Failed to kill PID \(pid): \(error)")
        }
    }

    static func killProcessGroup(pattern: String, mode: KillMode = .safe) -> [(pid: Int32, name: String, success: Bool, message: String)] {
        let allProcesses = ProcessCollector.getAllProcessesWithCPU(minMemoryMB: 0)
        let matchingProcesses = allProcesses.filter { process in
            process.name.range(of: pattern, options: .regularExpression) != nil
        }

        var results: [(Int32, String, Bool, String)] = []

        for process in matchingProcesses {
            let criticality = assessCriticality(processName: process.name, pid: process.pid)

            // Skip critical processes
            if criticality == .critical {
                results.append((process.pid, process.name, false, "❌ SKIPPED: Critical system process"))
                continue
            }

            let result = killProcess(pid: process.pid, mode: mode)
            results.append((process.pid, process.name, result.success, result.message))
        }

        return results
    }

    static func isProcessRunning(pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }
}

struct PortManager {
    struct PortInfo {
        let port: Int32
        let pid: Int32
        let processName: String
        let isAvailable: Bool
        let criticality: ProcessManager.ProcessCriticality
    }

    static func checkPort(_ port: Int32) -> PortInfo? {
        let processes = PortCollector.getProcessesOnPorts(portRange: port...port)

        if processes.isEmpty {
            return PortInfo(port: port, pid: 0, processName: "", isAvailable: true, criticality: .normal)
        }

        let process = processes[0]
        let criticality = ProcessManager.assessCriticality(processName: process.name, pid: process.pid)

        return PortInfo(
            port: port,
            pid: process.pid,
            processName: process.name,
            isAvailable: false,
            criticality: criticality
        )
    }

    static func checkPortRange(_ portRange: ClosedRange<Int32>) -> [PortInfo] {
        var results: [PortInfo] = []
        let processes = PortCollector.getProcessesOnPorts(portRange: portRange)

        // Create a map of port -> process
        var portMap: [Int32: ProcessInfo] = [:]
        for process in processes {
            for port in process.ports {
                portMap[port] = process
            }
        }

        // Check each port in range
        for port in portRange {
            if let process = portMap[port] {
                let criticality = ProcessManager.assessCriticality(processName: process.name, pid: process.pid)
                results.append(PortInfo(
                    port: port,
                    pid: process.pid,
                    processName: process.name,
                    isAvailable: false,
                    criticality: criticality
                ))
            } else {
                results.append(PortInfo(
                    port: port,
                    pid: 0,
                    processName: "",
                    isAvailable: true,
                    criticality: .normal
                ))
            }
        }

        return results
    }

    static func findFreePorts(in portRange: ClosedRange<Int32>, count: Int = 1) -> [Int32] {
        let portInfos = checkPortRange(portRange)
        return portInfos
            .filter { $0.isAvailable }
            .prefix(count)
            .map { $0.port }
    }
}

import Foundation

struct SystemMetrics {
    let totalMemoryGB: Double
    let usedMemoryGB: Double
    let freeMemoryGB: Double
    let freePercent: Double
    let swapUsedMB: Double
    let swapTotalMB: Double
    let swapFreePercent: Double
    let pressure: String

    static func current() -> SystemMetrics {
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
}

struct ProcessInfo {
    let pid: Int32
    let name: String
    let memoryMB: Double
    let percentMemory: Double
    let cpuPercent: Double
    let ports: [Int32]

    var description: String {
        let pidStr = String(format: "%5d", pid)
        let memStr = String(format: "%7.1f MB", memoryMB)
        let cpuStr = String(format: "%5.1f%%", cpuPercent)
        let pctStr = String(format: "%5.1f%%", percentMemory)
        let portsStr = ports.isEmpty ? "" : " [Ports: \(ports.map(String.init).joined(separator: ", "))]"
        return "\(pidStr)  \(memStr)  \(cpuStr)  \(pctStr)  \(name)\(portsStr)"
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
                    memoryMB: info.memoryMB,
                    percentMemory: info.percentMemory,
                    cpuPercent: info.cpuPercent,
                    ports: ports.sorted()
                ))
            }
        }

        processes.sort { $0.memoryMB > $1.memoryMB }
        return processes
    }
}

struct ProcessCollector {
    static func getAllProcesses(minMemoryMB: Double = 10) -> [(pid: Int32, name: String, memoryMB: Double, percentMemory: Double)] {
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

    static func getProcessInfo(pid: Int32) -> (pid: Int32, name: String, memoryMB: Double, percentMemory: Double, cpuPercent: Double)? {
        // Get process name
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))

        var name: String
        if pathLen > 0 {
            let pathData = Data(bytes: pathBuf, count: pathBuf.firstIndex(of: 0) ?? pathBuf.count)
            let path = String(decoding: pathData, as: UTF8.self)
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

        // Calculate CPU percentage
        let totalTime = taskInfo.pti_total_user + taskInfo.pti_total_system
        let cpuPercent = Double(totalTime) / 10_000_000.0 // Convert to percentage

        return (pid, name, memoryMB, percentMemory, cpuPercent)
    }

    static func getAllProcessesWithCPU(minMemoryMB: Double = 10) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []
        var pids = [pid_t](repeating: 0, count: 2048)

        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard result > 0 else { return [] }

        let processCount = Int(result) / MemoryLayout<pid_t>.size

        for i in 0..<processCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            if let info = getProcessInfo(pid: pid), info.memoryMB >= minMemoryMB {
                processes.append(ProcessInfo(
                    pid: info.pid,
                    name: info.name,
                    memoryMB: info.memoryMB,
                    percentMemory: info.percentMemory,
                    cpuPercent: info.cpuPercent,
                    ports: []
                ))
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

    static func isProcessRunning(pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }
}

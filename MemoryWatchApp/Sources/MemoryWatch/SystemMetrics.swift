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
        let totalPages = ProcessInfo.processInfo.physicalMemory / UInt64(pageSize)
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

struct ProcessCollector {
    static func getAllProcesses(minMemoryMB: Double = 10) -> [(pid: Int32, name: String, memoryMB: Double, percentMemory: Double)] {
        var processes: [(Int32, String, Double, Double)] = []
        var pids = [pid_t](repeating: 0, count: 2048)

        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard result > 0 else { return [] }

        let processCount = Int(result) / MemoryLayout<pid_t>.size
        var successCount = 0

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
            let percentMemory = (Double(memoryBytes) / Double(ProcessInfo.processInfo.physicalMemory)) * 100

            if memoryMB >= minMemoryMB {
                processes.append((pid, name, memoryMB, percentMemory))
                successCount += 1
            }
        }

        processes.sort { $0.2 > $1.2 }
        return processes
    }
}

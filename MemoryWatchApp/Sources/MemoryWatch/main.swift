import Foundation

// Simple CLI version of MemoryWatch
print("MemoryWatch - macOS Memory Monitor")
print("===================================")
print("")

func getSystemMemory() -> (total: Double, used: Double, free: Double) {
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

func getSwapUsage() -> (used: Double, total: Double) {
    var swapUsage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size

    let result = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)
    guard result == 0 else { return (0, 0) }

    let usedMB = Double(swapUsage.xsu_used) / 1_048_576
    let totalMB = Double(swapUsage.xsu_total) / 1_048_576

    return (usedMB, totalMB)
}

func getTopProcesses(count: Int = 10) -> [(pid: Int32, name: String, memoryMB: Double)] {
    var processes: [(Int32, String, Double)] = []
    var pids = [pid_t](repeating: 0, count: 2048)

    let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard result > 0 else { return [] }

    let processCount = Int(result) / MemoryLayout<pid_t>.size

    for i in 0..<processCount {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var buffer = [CChar](repeating: 0, count: 4096) // MAXPATHLEN * 4
        proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = String(cString: buffer)
        let name = path.components(separatedBy: "/").last ?? "Unknown"

        var taskInfo = task_vm_info_data_t()
        var taskInfoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        var task: task_t = 0
        guard task_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { continue }

        let infoResult = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) {
                task_info(task, task_flavor_t(TASK_VM_INFO), $0, &taskInfoCount)
            }
        }

        guard infoResult == KERN_SUCCESS else { continue }

        let memoryMB = Double(taskInfo.phys_footprint) / 1_048_576

        if memoryMB > 10 {
            processes.append((pid, name, memoryMB))
        }
    }

    processes.sort { $0.2 > $1.2 }
    return Array(processes.prefix(count))
}

// Main monitoring loop
print("Collecting system information...")
print("")

let memory = getSystemMemory()
print("System Memory:")
print("  Total:  \(String(format: "%.1f", memory.total)) GB")
print("  Used:   \(String(format: "%.1f", memory.used)) GB")
print("  Free:   \(String(format: "%.1f", memory.free)) GB")
print("  Free %: \(String(format: "%.1f", (memory.free / memory.total) * 100))%")
print("")

let swap = getSwapUsage()
print("Swap Usage:")
print("  Used:  \(String(format: "%.0f", swap.used)) MB")
print("  Total: \(String(format: "%.0f", swap.total)) MB")
if swap.total > 0 {
    print("  Free:  \(String(format: "%.1f", ((swap.total - swap.used) / swap.total) * 100))%")
}
print("")

print("Top Memory Consumers:")
print("  PID     Memory      Process")
print("  ---     ------      -------")
for process in getTopProcesses(count: 15) {
    let pidStr = String(format: "%5d", process.pid)
    let memStr = String(format: "%6.0f MB", process.memoryMB)
    print("  \(pidStr)  \(memStr)    \(process.name)")
}
print("")
print("For continuous monitoring, run: ./memory_watcher.sh")
print("For detailed analysis, run: ./analyze.py")

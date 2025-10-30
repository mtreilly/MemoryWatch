import Foundation
import Combine

struct ProcessInfo: Identifiable {
    let id: Int32 // PID
    let name: String
    let memoryMB: Double
    let percentMemory: Double
    var growthMB: Double = 0
    var isPotentialLeak: Bool = false
}

struct SwapInfo {
    let usedMB: Double
    let totalMB: Double
    let freePct: Double
}

struct SystemMemory {
    let totalGB: Double
    let usedGB: Double
    let freeGB: Double
    let freePct: Double
    let pressure: String
}

class MemoryMonitor: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    @Published var swapInfo: SwapInfo = SwapInfo(usedMB: 0, totalMB: 0, freePct: 100)
    @Published var systemMemory: SystemMemory = SystemMemory(totalGB: 0, usedGB: 0, freeGB: 0, freePct: 0, pressure: "Normal")
    @Published var alerts: [String] = []

    private var timer: Timer?
    private var processHistory: [Int32: Double] = [:] // Track RSS over time
    private let leakThresholdMB: Double = 100.0

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        updateMetrics()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func updateMetrics() {
        updateSystemMemory()
        updateSwapInfo()
        updateProcessList()
    }

    private func updateSystemMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = Double(vm_page_size)
        let totalPages = ProcessInfo.processInfo.physicalMemory / UInt64(pageSize)
        let freePages = UInt64(stats.free_count)
        let activePages = UInt64(stats.active_count)
        let inactivePages = UInt64(stats.inactive_count)
        let wiredPages = UInt64(stats.wire_count)

        let usedPages = activePages + wiredPages
        let totalBytes = Double(totalPages) * pageSize
        let usedBytes = Double(usedPages) * pageSize
        let freeBytes = Double(freePages + inactivePages) * pageSize

        let totalGB = totalBytes / 1_073_741_824
        let usedGB = usedBytes / 1_073_741_824
        let freeGB = freeBytes / 1_073_741_824
        let freePct = (freeBytes / totalBytes) * 100

        // Estimate pressure based on free percentage
        let pressure: String
        if freePct > 50 {
            pressure = "Normal"
        } else if freePct > 25 {
            pressure = "Warning"
        } else {
            pressure = "Critical"
        }

        DispatchQueue.main.async {
            self.systemMemory = SystemMemory(
                totalGB: totalGB,
                usedGB: usedGB,
                freeGB: freeGB,
                freePct: freePct,
                pressure: pressure
            )
        }
    }

    private func updateSwapInfo() {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        let result = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)
        guard result == 0 else { return }

        let usedMB = Double(swapUsage.xsu_used) / 1_048_576
        let totalMB = Double(swapUsage.xsu_total) / 1_048_576
        let freePct = totalMB > 0 ? ((totalMB - usedMB) / totalMB) * 100 : 100

        DispatchQueue.main.async {
            self.swapInfo = SwapInfo(usedMB: usedMB, totalMB: totalMB, freePct: freePct)

            // Alert if swap usage is high
            if usedMB > 1024 && !self.alerts.contains(where: { $0.contains("High swap") }) {
                self.alerts.append("High swap usage detected: \(String(format: "%.0f", usedMB))MB")
            }
        }
    }

    private func updateProcessList() {
        var count: mach_msg_type_number_t = 0
        var pids = [pid_t](repeating: 0, count: 2048)

        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard result > 0 else { return }

        let processCount = Int(result) / MemoryLayout<pid_t>.size
        var processes: [ProcessInfo] = []

        for i in 0..<processCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // Get process name
            var buffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
            proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path = String(cString: buffer)
            let name = path.components(separatedBy: "/").last ?? "Unknown"

            // Get memory info
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

            let memoryBytes = Double(taskInfo.phys_footprint)
            let memoryMB = memoryBytes / 1_048_576
            let percentMemory = (memoryBytes / Double(ProcessInfo.processInfo.physicalMemory)) * 100

            // Check for memory growth
            var growthMB: Double = 0
            var isPotentialLeak = false
            if let previousMB = processHistory[pid] {
                growthMB = memoryMB - previousMB
                if growthMB > leakThresholdMB {
                    isPotentialLeak = true
                }
            }
            processHistory[pid] = memoryMB

            // Only include processes using > 10MB
            if memoryMB > 10 {
                processes.append(ProcessInfo(
                    id: pid,
                    name: name,
                    memoryMB: memoryMB,
                    percentMemory: percentMemory,
                    growthMB: growthMB,
                    isPotentialLeak: isPotentialLeak
                ))
            }
        }

        // Sort by memory usage
        processes.sort { $0.memoryMB > $1.memoryMB }

        DispatchQueue.main.async {
            self.processes = Array(processes.prefix(20)) // Top 20
        }
    }

    func checkLeaks() {
        // Manually trigger leak detection
        let leaks = processes.filter { $0.isPotentialLeak }
        if !leaks.isEmpty {
            let message = "Found \(leaks.count) potential leak(s): " + leaks.map { $0.name }.joined(separator: ", ")
            alerts.append(message)
        } else {
            alerts.append("No memory leaks detected")
        }
    }

    deinit {
        stopMonitoring()
    }
}

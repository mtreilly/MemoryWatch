import Foundation

/// Detects and reports on orphaned resources that may consume memory
/// Includes deleted-but-open files, stale swapfiles, and zombie processes
public class OrphanDetector {
    private let lock = NSLock()

    // Configuration
    private let staleSwapfileDurationHours: TimeInterval
    private let maxDeletedFilesPerReport: Int
    private let orphanProcessCheckInterval: TimeInterval

    // State
    private var lastOrphanCheck: Date = .distantPast
    private var knownDeletedFiles: [String: Date] = [:]

    /// Initialize the orphan detector
    /// - Parameters:
    ///   - staleSwapfileDurationHours: Hours before swapfile is considered stale (default: 2)
    ///   - maxDeletedFilesPerReport: Max deleted files to report in one check (default: 50)
    ///   - orphanProcessCheckInterval: Minimum time between orphan process checks (default: 5 min)
    public init(staleSwapfileDurationHours: TimeInterval = 2,
                maxDeletedFilesPerReport: Int = 50,
                orphanProcessCheckInterval: TimeInterval = 300) {
        self.staleSwapfileDurationHours = staleSwapfileDurationHours
        self.maxDeletedFilesPerReport = maxDeletedFilesPerReport
        self.orphanProcessCheckInterval = orphanProcessCheckInterval
    }

    /// Find deleted-but-open files that may be consuming disk space
    /// - Parameters:
    ///   - pid: Optional process ID to filter results (nil = all processes)
    /// - Returns: Array of deleted file reports
    public func findDeletedOpenFiles(for pid: Int32? = nil) -> [DeletedFileReport] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")

        var arguments = ["-d", "cwd", "-d", "rtd"]  // current working directory, root directory
        if let pid = pid {
            arguments.append("-p")
            arguments.append(String(pid))
        }

        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // Suppress errors

        var reports: [DeletedFileReport] = []

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }

            let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

            for line in lines {
                let components = line.split(separator: /\s+/, omittingEmptySubsequences: true)
                guard components.count >= 9 else { continue }

                let command = String(components[0])
                let filePid = Int32(components[1]) ?? 0
                let nameStr = components[8...].joined(separator: " ")

                // Look for deleted files (marked with (deleted) suffix)
                if nameStr.contains("(deleted)") {
                    let fileSize = getFileSize(nameStr)
                    let report = DeletedFileReport(
                        processID: filePid,
                        processName: command,
                        filePath: String(nameStr.replacingOccurrences(of: " (deleted)", with: "")),
                        estimatedBytes: fileSize,
                        firstDetected: knownDeletedFiles[nameStr] ?? Date()
                    )
                    reports.append(report)

                    // Track when we first saw this file
                    lock.lock()
                    knownDeletedFiles[nameStr] = knownDeletedFiles[nameStr] ?? Date()
                    lock.unlock()
                }
            }

            // Limit results
            return Array(reports.prefix(maxDeletedFilesPerReport))
        } catch {
            return []
        }
    }

    /// Find stale swapfiles that may be accumulating on disk
    /// - Returns: Array of stale swapfile reports
    public func findStaleSwapfiles() -> [SwapfileReport] {
        let vmDir = "/var/vm"
        var reports: [SwapfileReport] = []

        guard let fileManager = FileManager.default as? FileManager,
              let contents = try? fileManager.contentsOfDirectory(atPath: vmDir) else {
            return []
        }

        let now = Date()

        for filename in contents {
            guard filename.hasPrefix("swapfile") else { continue }

            let filepath = "\(vmDir)/\(filename)"

            guard let attributes = try? fileManager.attributesOfItem(atPath: filepath),
                  let fileSize = attributes[.size] as? NSNumber,
                  let modDate = attributes[.modificationDate] as? Date else {
                continue
            }

            let ageDays = now.timeIntervalSince(modDate) / 86400

            // Consider stale if it hasn't been modified in the configured duration
            if ageDays > staleSwapfileDurationHours / 24 {
                let report = SwapfileReport(
                    filename: filename,
                    filepath: filepath,
                    sizeBytes: fileSize.int64Value,
                    lastModified: modDate,
                    ageHours: now.timeIntervalSince(modDate) / 3600
                )
                reports.append(report)
            }
        }

        return reports.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Find zombie and orphaned processes
    /// - Returns: Array of orphaned process reports
    public func findOrphanedProcesses() -> [OrphanedProcessReport] {
        let now = Date()

        guard now.timeIntervalSince(lastOrphanCheck) >= orphanProcessCheckInterval else {
            return []
        }

        lock.lock()
        lastOrphanCheck = now
        lock.unlock()

        var reports: [OrphanedProcessReport] = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["aux"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }

            let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

            for line in lines {
                let components = line.split(separator: /\s+/, omittingEmptySubsequences: true)
                guard components.count >= 11 else { continue }

                let stat = String(components[7])  // STAT column
                let pidStr = String(components[1])
                let command = String(components[10])

                guard let pid = Int32(pidStr) else { continue }

                // Look for zombie processes (Z in STAT field)
                if stat.contains("Z") {
                    let report = OrphanedProcessReport(
                        processID: pid,
                        processName: command,
                        state: "Zombie",
                        parentProcessID: 1,  // Zombies are typically reparented to init
                        createdAt: Date(),
                        estimatedMemoryBytes: 0  // Zombies use minimal memory
                    )
                    reports.append(report)
                }

                // Look for suspended processes that might be orphaned
                if stat.contains("T") && !command.contains("debugserver") {
                    let report = OrphanedProcessReport(
                        processID: pid,
                        processName: command,
                        state: "Suspended",
                        parentProcessID: 1,
                        createdAt: Date(),
                        estimatedMemoryBytes: 0
                    )
                    reports.append(report)
                }
            }
        } catch {
            return []
        }

        return reports
    }

    /// Get the bundle path for a given process ID
    /// - Parameters:
    ///   - pid: Process ID to look up
    /// - Returns: Bundle path if found, nil otherwise
    public func getBundlePath(for pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(pid)]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }

            // Check if this is an app bundle
            if path.contains(".app/Contents/") || path.hasSuffix(".app") {
                // Extract the .app bundle path
                if let range = path.range(of: ".app") {
                    return String(path[...range.lowerBound]) + ".app"
                }
            }

            return path.hasPrefix("/") ? path : nil
        } catch {
            return nil
        }
    }

    /// Generate remediation suggestions for a detected orphan
    /// - Parameters:
    ///   - report: The orphan report
    /// - Returns: Array of actionable suggestions
    public func getRemediationSuggestions(for report: OrphanReport) -> [String] {
        var suggestions: [String] = []

        switch report {
        case .deletedFile(let fileReport):
            suggestions.append("File '\(fileReport.filename)' is deleted but still open")
            suggestions.append("Restart process \(fileReport.processName) (PID \(fileReport.processID)) to release the file")
            suggestions.append("Free space by terminating: `kill -9 \(fileReport.processID)`")

            if fileReport.estimatedBytes > 100_000_000 {
                suggestions.append("WARNING: File is over 100MB - restart is recommended")
            }

        case .staleSwapfile(let swapReport):
            suggestions.append("Swapfile '\(swapReport.filename)' is stale (modified \(Int(swapReport.ageHours))h ago)")
            suggestions.append("Free \(OrphanDetector.formatBytes(swapReport.sizeBytes)) by clearing swap: `sudo rm \(swapReport.filepath)`")
            suggestions.append("Restart system to automatically clean up swap files")

        case .orphanedProcess(let procReport):
            suggestions.append("Process '\(procReport.processName)' is in state: \(procReport.state)")

            if procReport.state == "Zombie" {
                suggestions.append("Terminate parent process to reap zombie")
                suggestions.append("Or restart system if parent cannot be found")
            } else if procReport.state == "Suspended" {
                suggestions.append("Resume or terminate suspended process: `kill -CONT \(procReport.processID)`")
            }
        }

        return suggestions
    }

    // MARK: - Private

    private func getFileSize(_ filePath: String) -> Int64 {
        let cleanPath = filePath.replacingOccurrences(of: " (deleted)", with: "")

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cleanPath),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }

        return size.int64Value
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Report Types

/// Report for a deleted-but-open file
public struct DeletedFileReport: Sendable {
    public let processID: Int32
    public let processName: String
    public let filePath: String
    public let estimatedBytes: Int64
    public let firstDetected: Date

    public var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    public var ageDays: Double {
        Date().timeIntervalSince(firstDetected) / 86400
    }
}

/// Report for a stale swapfile
public struct SwapfileReport: Sendable {
    public let filename: String
    public let filepath: String
    public let sizeBytes: Int64
    public let lastModified: Date
    public let ageHours: Double
}

/// Report for an orphaned/zombie process
public struct OrphanedProcessReport: Sendable {
    public let processID: Int32
    public let processName: String
    public let state: String  // "Zombie", "Suspended", etc.
    public let parentProcessID: Int32
    public let createdAt: Date
    public let estimatedMemoryBytes: Int64
}

/// Unified orphan report for alerts
public enum OrphanReport: Sendable {
    case deletedFile(DeletedFileReport)
    case staleSwapfile(SwapfileReport)
    case orphanedProcess(OrphanedProcessReport)

    public var type: String {
        switch self {
        case .deletedFile:
            return "Deleted Open File"
        case .staleSwapfile:
            return "Stale Swapfile"
        case .orphanedProcess:
            return "Orphaned Process"
        }
    }

    public var severity: String {
        switch self {
        case .deletedFile(let report):
            return report.estimatedBytes > 500_000_000 ? "high" : "medium"
        case .staleSwapfile(let report):
            return report.sizeBytes > 1_000_000_000 ? "high" : "medium"
        case .orphanedProcess(let report):
            return report.state == "Zombie" ? "medium" : "low"
        }
    }

    public var description: String {
        switch self {
        case .deletedFile(let report):
            return "Deleted file '\(report.filename)' still open by \(report.processName) (PID \(report.processID))"
        case .staleSwapfile(let report):
            return "Stale swapfile '\(report.filename)' (\(Self.formatBytes(report.sizeBytes)), modified \(Int(report.ageHours))h ago)"
        case .orphanedProcess(let report):
            return "\(report.state) process '\(report.processName)' (PID \(report.processID))"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

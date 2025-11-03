import Foundation

/// Protocol for runtime-specific toolchain adapters that capture and analyze memory artifacts
public protocol ToolchainAdapter: AnyObject {
    /// Runtime kind this adapter supports
    var runtime: RuntimeKind { get }

    /// Attempts to capture a memory diagnostic artifact for the given process
    /// - Returns: URL to captured artifact if successful, nil otherwise
    func captureArtifact(pid: Int32) -> URL?

    /// Analyzes the captured artifact and returns a summary
    /// - Returns: Analysis summary with key findings
    func analyzeArtifact(url: URL) -> ArtifactAnalysis?
}

/// Summary of artifact analysis
public struct ArtifactAnalysis: Codable {
    public let runtime: String
    public let artifactType: String
    public let summary: String
    public let keyFindings: [String]
    public let suspectedLeaks: [SuspectedLeak]
    public let analysisTimestamp: Date

    public struct SuspectedLeak: Codable {
        public let description: String
        public let severity: String  // "low", "medium", "high"
        public let estimatedBytes: Int64?
    }
}

/// Chromium-based browser heap dump adapter
public class ChromiumAdapter: ToolchainAdapter {
    public let runtime: RuntimeKind = .chrome
    private let workingDirectory: URL

    public init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public func captureArtifact(pid: Int32) -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let artifactName = "chromium_heap_\(pid)_\(timestamp).json"
        let artifactURL = workingDirectory.appendingPathComponent("artifacts").appendingPathComponent(artifactName)

        // Create artifacts directory if needed
        try? FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Send SIGUSR2 to trigger heap dump
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-USR2", String(pid)]

        do {
            try process.run()
            process.waitUntilExit()

            // Check if artifact was created in Chrome's profile directory
            // Note: actual path depends on Chrome's configuration
            // For now, return nil as we'd need to find Chrome's profile path
            return nil
        } catch {
            return nil
        }
    }

    public func analyzeArtifact(url: URL) -> ArtifactAnalysis? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Parse Chrome heap snapshot
        let findings = parseChromiumHeapDump(json)

        return ArtifactAnalysis(
            runtime: "Chromium",
            artifactType: "V8 Heap Dump",
            summary: "Chrome/Electron heap snapshot analysis",
            keyFindings: findings.summary,
            suspectedLeaks: findings.leaks,
            analysisTimestamp: Date()
        )
    }

    private func parseChromiumHeapDump(_ json: [String: Any]) -> (summary: [String], leaks: [ArtifactAnalysis.SuspectedLeak]) {
        var summary: [String] = []
        let leaks: [ArtifactAnalysis.SuspectedLeak] = []

        if let snapshot = json["snapshot"] as? [String: Any] {
            if let nodes = snapshot["nodes"] as? [Int] {
                summary.append("Total heap objects: \(nodes.count / 4)")  // nodes contains 4 values per object
            }
        }

        // Simplified analysis - in production would parse more thoroughly
        return (summary, leaks)
    }
}

/// Xcode malloc stack logging adapter
public class XcodeAdapter: ToolchainAdapter {
    public let runtime: RuntimeKind = .xcode
    private let workingDirectory: URL

    public init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public func captureArtifact(pid: Int32) -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let artifactName = "xcode_malloc_\(pid)_\(timestamp).trace"
        let artifactURL = workingDirectory.appendingPathComponent("artifacts").appendingPathComponent(artifactName)

        try? FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Use xcrun to capture allocation trace
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "xcrun xctrace record --template 'Allocations' --output \(artifactURL.path) --attach \(pid) --time-limit 30"]

        do {
            try process.run()
            // Set timeout of 35 seconds (30s trace + 5s overhead)
            let deadline = Date().addingTimeInterval(35)
            while process.isRunning && Date() < deadline {
                usleep(500_000)  // Poll every 0.5 seconds
            }

            if process.isRunning {
                process.terminate()
            }

            if FileManager.default.fileExists(atPath: artifactURL.path) {
                return artifactURL
            }
        } catch {
            return nil
        }

        return nil
    }

    public func analyzeArtifact(url: URL) -> ArtifactAnalysis? {
        // Trace files are binary; extract summary using xcrun
        var summary: [String] = []
        let leaks: [ArtifactAnalysis.SuspectedLeak] = []

        // Note: In production, would parse xcrun output or use private Xcode APIs
        summary.append("Captured Xcode malloc trace")

        return ArtifactAnalysis(
            runtime: "Xcode",
            artifactType: "Malloc Stack Log",
            summary: "Xcode allocation profile",
            keyFindings: summary,
            suspectedLeaks: leaks,
            analysisTimestamp: Date()
        )
    }
}

/// Node.js heap snapshot adapter
public class NodeAdapter: ToolchainAdapter {
    public let runtime: RuntimeKind = .node
    private let workingDirectory: URL

    public init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public func captureArtifact(pid: Int32) -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let artifactName = "node_heap_\(pid)_\(timestamp).heapsnapshot"
        let artifactURL = workingDirectory.appendingPathComponent("artifacts").appendingPathComponent(artifactName)

        try? FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Trigger Node.js inspector which outputs heap snapshot
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-USR2", String(pid)]

        do {
            try process.run()
            process.waitUntilExit()

            // Wait for snapshot to be written
            usleep(2_000_000)  // 2 second delay

            // Heap snapshots are typically written to working directory
            // Would need to find and copy them here
            return nil
        } catch {
            return nil
        }
    }

    public func analyzeArtifact(url: URL) -> ArtifactAnalysis? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let findings = parseNodeHeapSnapshot(json)

        return ArtifactAnalysis(
            runtime: "Node.js",
            artifactType: "Heap Snapshot",
            summary: "Node.js V8 heap snapshot analysis",
            keyFindings: findings.summary,
            suspectedLeaks: findings.leaks,
            analysisTimestamp: Date()
        )
    }

    private func parseNodeHeapSnapshot(_ json: [String: Any]) -> (summary: [String], leaks: [ArtifactAnalysis.SuspectedLeak]) {
        var summary: [String] = []
        var leaks: [ArtifactAnalysis.SuspectedLeak] = []

        if let nodes = json["nodes"] as? [Int] {
            summary.append("Heap objects: \(nodes.count / 7)")  // Node snapshot has 7 fields per node
        }

        // Analyze for common leak patterns
        if let strings = json["strings"] as? [String] {
            let suspiciousPatterns = ["detached", "listener", "callback", "closure"]
            let matches = strings.filter { str in
                suspiciousPatterns.contains { pattern in str.lowercased().contains(pattern) }
            }

            if !matches.isEmpty {
                leaks.append(ArtifactAnalysis.SuspectedLeak(
                    description: "Found \(matches.count) objects matching leak patterns",
                    severity: "medium",
                    estimatedBytes: nil
                ))
            }
        }

        return (summary, leaks)
    }
}

/// Registry of available toolchain adapters
public class ToolchainAdapterRegistry {
    private var adapters: [RuntimeKind: ToolchainAdapter] = [:]

    public init() {
        // Register default adapters
        let workDir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        adapters[.chrome] = ChromiumAdapter(workingDirectory: workDir)
        adapters[.xcode] = XcodeAdapter(workingDirectory: workDir)
        adapters[.node] = NodeAdapter(workingDirectory: workDir)
        // Electron uses the same Chrome adapter
        adapters[.electron] = ChromiumAdapter(workingDirectory: workDir)
    }

    public func adapter(for runtime: RuntimeKind) -> ToolchainAdapter? {
        return adapters[runtime]
    }

    public func register(_ adapter: ToolchainAdapter, for runtime: RuntimeKind) {
        adapters[runtime] = adapter
    }
}

# MemoryWatch Developer Integration Guide

## Overview

MemoryWatch is designed for extension and integration. This guide explains how to:
- Build custom runtime adapters for new languages/frameworks
- Integrate with external monitoring systems
- Extend leak detection heuristics
- Create custom orphan detectors

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│        MemoryWatch Core Components              │
├─────────────────────────────────────────────────┤
│                                                 │
│  ProcessMonitor ──→ SystemMetrics ──→ SQLiteStore
│       ↓                              ↓
│    Snapshots                    Persistence
│                                                 │
│  LeakHeuristics ──→ MemoryAlert ──→ SQLiteStore
│       ↓                    ↓
│    Detection         Notifications
│                                                 │
│  OrphanDetector ──→ OrphanReport ──→ SQLiteStore
│       ↓                                         │
│    Cleanup                                      │
│                                                 │
├─────────────────────────────────────────────────┤
│          Extensibility Points                   │
├─────────────────────────────────────────────────┤
│                                                 │
│  ToolchainAdapter (Custom Runtimes)             │
│  ToolchainAdapterRegistry (Adapter Discovery)   │
│  ToolchainIntegration (Artifact Capture)        │
│                                                 │
│  LeakHeuristics (Detection Logic)               │
│  OrphanDetector (Resource Scanning)             │
│                                                 │
└─────────────────────────────────────────────────┘
```

## Custom Toolchain Adapters

### Overview

A **ToolchainAdapter** captures runtime-specific diagnostic artifacts (heap dumps, stack traces) and analyzes them for memory leaks.

### Adapter Protocol

```swift
public protocol ToolchainAdapter {
    var runtime: RuntimeKind { get }
    func captureArtifact(for pid: Int32, outputDirectory: URL) throws -> URL
    func analyzeArtifact(at path: URL) throws -> ArtifactAnalysis
}
```

### Implementing a Custom Adapter

Example: Adapter for Python memory profiling

```swift
import Foundation

public class PythonAdapter: ToolchainAdapter {
    public let runtime: RuntimeKind = .python

    // MARK: - Artifact Capture

    public func captureArtifact(
        for pid: Int32,
        outputDirectory: URL
    ) throws -> URL {
        // Step 1: Verify Python process
        guard try isPythonProcess(pid) else {
            throw AdapterError.processMismatch
        }

        // Step 2: Send signal to capture heap
        let signal = SIGUSR1  // Python's profiler signal
        kill(pid, signal)
        sleep(1)  // Wait for profile generation

        // Step 3: Locate generated profile
        let profilePath = try findGeneratedProfile(pid)

        // Step 4: Copy to artifacts directory
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let artifactName = "python_profile_\(pid)_\(timestamp).json"
        let destURL = outputDirectory.appendingPathComponent(artifactName)

        try FileManager.default.copyItem(atPath: profilePath, toPath: destURL.path)

        return destURL
    }

    public func analyzeArtifact(at path: URL) throws -> ArtifactAnalysis {
        // Step 1: Parse JSON profile
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.parseError
        }

        // Step 2: Analyze memory growth patterns
        let leaks = analyzePythonHeap(json)

        // Step 3: Generate findings
        let findings = leaks.map { leak in
            "Potential leak in \(leak.module) - \(leak.allocCount) allocations"
        }

        return ArtifactAnalysis(
            runtime: .python,
            artifactType: "Memory Profile",
            summary: "Found \(leaks.count) potential leaks",
            keyFindings: findings,
            suspectedLeaks: leaks.map { $0.module },
            analysisTimestamp: Date()
        )
    }

    // MARK: - Private Helpers

    private func isPythonProcess(_ pid: Int32) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return output.lowercased().contains("python")
    }

    private func findGeneratedProfile(_ pid: Int32) throws -> String {
        let tmpDir = "/tmp"
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(atPath: tmpDir)

        // Look for recently modified profile files
        let profileFiles = files.filter { $0.contains("pstats") || $0.contains("profile") }
            .map { "\(tmpDir)/\($0)" }
            .sorted { path1, path2 in
                let attrs1 = try? fileManager.attributesOfItem(atPath: path1)
                let attrs2 = try? fileManager.attributesOfItem(atPath: path2)
                let date1 = (attrs1?[.modificationDate] as? Date) ?? .distantPast
                let date2 = (attrs2?[.modificationDate] as? Date) ?? .distantPast
                return date1 > date2
            }

        guard let latest = profileFiles.first else {
            throw AdapterError.artifactNotFound
        }

        return latest
    }

    private func analyzePythonHeap(_ json: [String: Any]) -> [LeakInfo] {
        // Parse the Python memory profile and identify leaks
        var leaks: [LeakInfo] = []

        if let allocations = json["allocations"] as? [[String: Any]] {
            for alloc in allocations {
                let module = alloc["module"] as? String ?? "unknown"
                let count = alloc["count"] as? Int ?? 0

                // Mark as leak if growth rate is abnormal
                if count > 10000 {
                    leaks.append(LeakInfo(module: module, allocCount: count))
                }
            }
        }

        return leaks
    }
}

struct LeakInfo {
    let module: String
    let allocCount: Int
}

enum AdapterError: Error {
    case processMismatch
    case parseError
    case artifactNotFound
}
```

### Registering Custom Adapters

Register your adapter with the system:

```swift
import MemoryWatchCore

let registry = ToolchainAdapterRegistry()

// Register custom Python adapter
let pythonAdapter = PythonAdapter()
registry.registerAdapter(pythonAdapter)

// Register with integration layer
let integration = ToolchainIntegration(
    adapterRegistry: registry,
    store: sqliteStore
)

// Now diagnostics will use your adapter
memwatch diagnostics 1234 --all-runtimes  // Includes Python
```

## Extending Leak Detection

### Heuristics Overview

LeakHeuristics uses regression analysis to detect memory leaks:

```swift
public class LeakHeuristics {
    // Detects linear growth pattern
    public static func analyzeProcess(
        pid: Int32,
        in store: SQLiteStore,
        minGrowthMB: Double = 50
    ) -> LeakSuspicion
}
```

### Custom Heuristics

Implement alternative leak detection:

```swift
public class CustomLeakDetector {
    /// Detects leaks using moving average crossover
    public static func detectLeaksWithMovingAverage(
        snapshots: [ProcessSnapshot],
        windowSize: Int = 10,
        threshold: Double = 1.5
    ) -> [LeakSuspicion] {
        guard snapshots.count >= windowSize * 2 else { return [] }

        // Calculate moving averages
        var shortMA: [Double] = []
        var longMA: [Double] = []

        let shortWindow = windowSize
        let longWindow = windowSize * 2

        for i in longWindow..<snapshots.count {
            let shortAvg = snapshots[(i-shortWindow+1)...i]
                .map { $0.memoryMB }
                .reduce(0, +) / Double(shortWindow)
            let longAvg = snapshots[(i-longWindow+1)...i]
                .map { $0.memoryMB }
                .reduce(0, +) / Double(longWindow)

            shortMA.append(shortAvg)
            longMA.append(longAvg)
        }

        // Detect crossovers (potential leaks)
        var suspicions: [LeakSuspicion] = []

        for i in 1..<shortMA.count {
            let ratio = shortMA[i] / longMA[i]

            if ratio > threshold {
                let growthMB = shortMA[i] - longMA[i]
                suspicions.append(LeakSuspicion(
                    suspicionLevel: ratio > 2.0 ? .critical : .high,
                    growth: growthMB,
                    confidence: ratio / threshold
                ))
            }
        }

        return suspicions
    }

    /// Detects leaks using machine learning (simple anomaly detection)
    public static func detectLeaksWithAnomalyDetection(
        snapshots: [ProcessSnapshot],
        stdDevThreshold: Double = 2.5
    ) -> [LeakSuspicion] {
        let memories = snapshots.map { $0.memoryMB }

        let mean = memories.reduce(0, +) / Double(memories.count)
        let variance = memories
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(memories.count)
        let stdDev = sqrt(variance)

        var suspicions: [LeakSuspicion] = []

        for (index, memory) in memories.enumerated() {
            let zScore = abs(memory - mean) / stdDev

            if zScore > stdDevThreshold && memory > mean {
                suspicions.append(LeakSuspicion(
                    suspicionLevel: .high,
                    growth: memory - mean,
                    confidence: zScore / stdDevThreshold
                ))
            }
        }

        return suspicions
    }
}
```

### Integration with Core

Replace or augment the default heuristics:

```swift
let store = try SQLiteStore(url: databaseURL)
let snapshots = store.getRecentSnapshots(hoursBack: 24)

// Use custom detector instead of default
let suspicions = CustomLeakDetector.detectLeaksWithMovingAverage(
    snapshots: snapshots,
    windowSize: 5,
    threshold: 1.8
)

// Generate alerts
for suspicion in suspicions {
    let alert = MemoryAlert(
        timestamp: Date(),
        type: .memoryLeak,
        message: "Custom detector found leak",
        pid: 1234,
        processName: "MyApp",
        metadata: [
            "detector": "moving_average",
            "growth_mb": "\(suspicion.growth)",
            "confidence": "\(suspicion.confidence)"
        ]
    )
    store.insertAlert(alert)
}
```

## Custom Orphan Detectors

### Extending OrphanDetector

Detect custom resource types:

```swift
public extension OrphanDetector {
    /// Detect memory-mapped files consuming swap space
    func findMemoryMappedFiles() -> [MemoryMappedFileReport] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-c", "/REG/"]  // Regular files only

        let pipe = Pipe()
        process.standardOutput = pipe

        var reports: [MemoryMappedFileReport] = []

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }

            let lines = output.split(separator: "\n")

            for line in lines {
                let components = line.split(separator: /\s+/)
                guard components.count >= 9 else { continue }

                let processName = String(components[0])
                let pid = Int32(components[1]) ?? 0
                let size = parseSize(String(components[7]))

                // Report large mmapped files
                if size > 100_000_000 {  // 100MB+
                    reports.append(MemoryMappedFileReport(
                        processID: pid,
                        processName: processName,
                        sizeBytes: size,
                        firstDetected: Date()
                    ))
                }
            }
        } catch { }

        return reports
    }

    private func parseSize(_ sizeStr: String) -> Int64 {
        let cleanSize = sizeStr.replacingOccurrences(of: "[A-Za-z]", with: "", options: .regularExpression)
        return Int64(cleanSize) ?? 0
    }
}

public struct MemoryMappedFileReport: Sendable {
    public let processID: Int32
    public let processName: String
    public let sizeBytes: Int64
    public let firstDetected: Date
}
```

## Database Schema Customization

### Adding Custom Tables

Extend SQLiteStore with custom metrics:

```swift
public extension SQLiteStore {
    func recordCustomMetric(
        name: String,
        value: Double,
        timestamp: Date = Date(),
        metadata: [String: String]? = nil
    ) throws {
        let sql = """
            INSERT INTO custom_metrics (name, value, timestamp, metadata)
            VALUES (?, ?, ?, ?)
        """

        let metadataJSON = metadata.map { dict in
            try? JSONSerialization.data(withJSONObject: dict)
        }

        try execute(sql, parameters: [
            name,
            value,
            timestamp.timeIntervalSince1970,
            metadataJSON
        ])
    }

    func queryCustomMetrics(
        name: String,
        hoursBack: Int = 24
    ) throws -> [(timestamp: Date, value: Double)] {
        let sql = """
            SELECT timestamp, value FROM custom_metrics
            WHERE name = ?
            AND timestamp > datetime('now', '-\(hoursBack) hours')
            ORDER BY timestamp DESC
        """

        var results: [(timestamp: Date, value: Double)] = []

        // Execute query and parse results
        try execute(sql, parameters: [name]) { statement in
            while try statement.step() {
                let timestamp = Date(timeIntervalSince1970: statement.columnDouble(at: 0))
                let value = statement.columnDouble(at: 1)
                results.append((timestamp: timestamp, value: value))
            }
        }

        return results
    }
}
```

## Integration Patterns

### Real-Time Streaming

Stream metrics to external systems:

```swift
public class MetricStreamer {
    private let store: SQLiteStore
    private let endpoint: URL

    public init(store: SQLiteStore, endpoint: URL) {
        self.store = store
        self.endpoint = endpoint
    }

    public func startStreaming(interval: TimeInterval = 10) {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.flushMetrics()
        }
    }

    private func flushMetrics() {
        let snapshots = store.getRecentSnapshots(hoursBack: 1, maxCount: 100)

        let payload = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "snapshots": snapshots.map { snap in
                [
                    "pid": snap.pid,
                    "name": snap.name,
                    "memory_mb": snap.memoryMB,
                    "cpu_percent": snap.cpuPercent
                ]
            }
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("Stream error: \(error)")
                }
            }
            task.resume()
        } catch {
            print("Serialization error: \(error)")
        }
    }
}
```

### Alert Webhook Integration

Forward alerts to external systems:

```swift
public class AlertWebhook {
    private let webhookURL: URL
    private let store: SQLiteStore

    public init(webhookURL: URL, store: SQLiteStore) {
        self.webhookURL = webhookURL
        self.store = store
    }

    public func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkAndForwardAlerts()
        }
    }

    private func checkAndForwardAlerts() {
        let recentAlerts = store.getAlerts(hoursBack: 1)

        for alert in recentAlerts where alert.type == .memoryLeak {
            sendToWebhook(alert)
        }
    }

    private func sendToWebhook(_ alert: MemoryAlert) {
        let payload: [String: Any] = [
            "type": alert.type.rawValue,
            "pid": alert.pid,
            "process": alert.processName,
            "message": alert.message,
            "timestamp": ISO8601DateFormatter().string(from: alert.timestamp),
            "metadata": alert.metadata ?? [:]
        ]

        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            URLSession.shared.dataTask(with: request).resume()
        } catch {
            print("Webhook error: \(error)")
        }
    }
}
```

## Testing Custom Extensions

### Unit Testing Adapters

```swift
import XCTest
@testable import MemoryWatchCore

class CustomAdapterTests: XCTestCase {
    var adapter: PythonAdapter!

    override func setUp() {
        super.setUp()
        adapter = PythonAdapter()
    }

    func testAdapterIdentifiesCorrectRuntime() {
        XCTAssertEqual(adapter.runtime, .python)
    }

    func testAdapterHandlesInvalidProcess() {
        XCTAssertThrowsError(
            try adapter.captureArtifact(
                for: 999999,
                outputDirectory: URL(fileURLWithPath: "/tmp")
            )
        )
    }

    func testAdapterAnalyzesArtifact() {
        // Create mock artifact
        let artifact = """
        {
            "allocations": [
                {"module": "mylib", "count": 50000}
            ]
        }
        """

        let tempURL = URL(fileURLWithPath: "/tmp/test_profile.json")
        try? artifact.write(to: tempURL, atomically: true, encoding: .utf8)

        let analysis = try? adapter.analyzeArtifact(at: tempURL)

        XCTAssertNotNil(analysis)
        XCTAssertTrue(analysis?.keyFindings.count ?? 0 > 0)
    }
}
```

## Performance Considerations

### Memory Efficiency

When capturing artifacts:

1. **Stream Processing**: Parse large artifacts line-by-line, not all at once
2. **Cleanup**: Remove artifacts after analysis
3. **Limits**: Cap artifact size to prevent out-of-memory errors

```swift
private let maxArtifactSize = 500 * 1024 * 1024  // 500MB
private let maxRetainedArtifacts = 10

public func cleanupOldArtifacts() {
    let artifactDir = store.workingDirectory.appendingPathComponent("artifacts")
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: artifactDir,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }

    let sorted = files.sorted { file1, file2 in
        let date1 = (try? file1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let date2 = (try? file2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return date1 > date2
    }

    for file in sorted.dropFirst(maxRetainedArtifacts) {
        try? FileManager.default.removeItem(at: file)
    }
}
```

## See Also

- [SQLiteStore API Reference](SQLITE_API.md)
- [CLI Reference](CLI_REFERENCE.md)
- [System Entitlements Guide](ENTITLEMENTS.md)

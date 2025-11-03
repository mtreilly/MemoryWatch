import Foundation

/// Coordinates toolchain adapters with the monitoring and alerting system
/// Captures artifacts when high-suspicion leaks are detected
public class ToolchainIntegration {
    private let registry: ToolchainAdapterRegistry
    private let store: SQLiteStore

    // Configuration
    private let artifactCaptureThreshold: Double  // Suspicion score that triggers artifact capture

    /// Initialize the toolchain integration
    /// - Parameters:
    ///   - store: SQLite store for saving artifact metadata
    ///   - artifactCaptureThreshold: Suspicion score (0-1) that triggers artifact capture (default: 0.7)
    public init(store: SQLiteStore,
                artifactCaptureThreshold: Double = 0.7) {
        self.store = store
        self.registry = ToolchainAdapterRegistry()
        self.artifactCaptureThreshold = artifactCaptureThreshold
    }

    /// Process an alert and capture artifacts if suspicion is high enough
    /// - Parameters:
    ///   - alert: The memory alert to process
    ///   - pid: Process ID to capture artifacts from
    ///   - runtime: Runtime kind of the process
    public func processAlertForArtifacts(alert: MemoryAlert, pid: Int32, runtime: RuntimeKind) {
        guard let suspicion = extractSuspicionScore(from: alert) else {
            return
        }

        // Only capture artifacts if suspicion is high enough
        guard suspicion >= artifactCaptureThreshold else {
            return
        }

        // Trigger async artifact capture
        captureArtifacts(for: pid, runtime: runtime, alert: alert)
    }

    /// Manually trigger artifact capture for a process
    /// - Parameters:
    ///   - pid: Process ID
    ///   - runtime: Runtime kind
    ///   - alert: Optional alert to enrich with artifact data
    public func captureArtifacts(for pid: Int32,
                                runtime: RuntimeKind,
                                alert: MemoryAlert? = nil) {
        // Use background queue to avoid Sendable closure constraints
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Get adapter for this runtime
            guard let adapter = self.registry.adapter(for: runtime) else {
                return
            }

            // Attempt to capture artifact
            guard let artifactURL = adapter.captureArtifact(pid: pid) else {
                return
            }

            // Analyze the captured artifact
            guard let analysis = adapter.analyzeArtifact(url: artifactURL) else {
                return
            }

            // Store artifact metadata in alert if provided
            if let originalAlert = alert {
                var metadata = originalAlert.metadata ?? [:]
                metadata["artifact_path"] = artifactURL.path
                metadata["artifact_type"] = analysis.artifactType
                metadata["artifact_runtime"] = analysis.runtime
                metadata["analysis_summary"] = analysis.summary
                metadata["suspected_leaks_count"] = String(analysis.suspectedLeaks.count)

                if !analysis.suspectedLeaks.isEmpty {
                    let severityArray = analysis.suspectedLeaks.map { $0.severity }
                    metadata["leak_severities"] = severityArray.joined(separator: ",")
                }

                // Create a new alert with updated metadata
                let enrichedAlert = MemoryAlert(
                    timestamp: originalAlert.timestamp,
                    type: originalAlert.type,
                    message: originalAlert.message,
                    pid: originalAlert.pid,
                    processName: originalAlert.processName,
                    metadata: metadata
                )

                // Save the enriched alert
                self.store.insertAlert(enrichedAlert)
            }
        }
    }

    /// Get diagnostics suggestions for a process that may have a leak
    /// - Parameters:
    ///   - pid: Process ID
    ///   - runtime: Runtime kind
    /// - Returns: Array of diagnostic suggestions with artifact paths if available
    public func getDiagnosticSuggestions(for pid: Int32, runtime: RuntimeKind) -> [DiagnosticSuggestion] {
        var suggestions: [DiagnosticSuggestion] = []

        // Get adapter-specific diagnostics
        if registry.adapter(for: runtime) != nil {
            let runtimeName = runtime.rawValue.capitalized
            suggestions.append(DiagnosticSuggestion(
                title: "Capture \(runtimeName) Artifact",
                command: "memwatch diagnostics \(pid)",
                note: "Captures a \(runtimeName) diagnostic artifact for analysis",
                artifactPath: nil
            ))
        }

        // Add standard suggestions based on runtime
        switch runtime {
        case .chrome, .electron:
            suggestions.append(contentsOf: [
                DiagnosticSuggestion(
                    title: "Chrome DevTools Memory Profiler",
                    command: "chrome://inspect",
                    note: "Open Chrome DevTools to profile memory usage",
                    artifactPath: nil
                ),
                DiagnosticSuggestion(
                    title: "Take Heap Snapshot",
                    command: "memwatch heap-snapshot \(pid)",
                    note: "Capture a V8 heap snapshot for detailed analysis",
                    artifactPath: nil
                )
            ])

        case .node:
            suggestions.append(contentsOf: [
                DiagnosticSuggestion(
                    title: "Node.js Heap Snapshot",
                    command: "node --inspect-brk=:9229 app.js",
                    note: "Enable Node inspector for heap profiling",
                    artifactPath: nil
                ),
                DiagnosticSuggestion(
                    title: "Check Node Event Listeners",
                    command: "memwatch listeners \(pid)",
                    note: "Identify accumulating event listeners",
                    artifactPath: nil
                )
            ])

        case .xcode:
            suggestions.append(DiagnosticSuggestion(
                title: "Xcode Memory Graph",
                command: "xcode://debug-memory-graph",
                note: "Use Xcode's memory graph debugger to find retained cycles",
                artifactPath: nil
            ))

        default:
            break
        }

        return suggestions
    }

    /// Register a custom adapter
    /// - Parameters:
    ///   - adapter: The adapter to register
    ///   - runtime: The runtime kind it handles
    public func registerAdapter(_ adapter: ToolchainAdapter, for runtime: RuntimeKind) {
        registry.register(adapter, for: runtime)
    }

    // MARK: - Private

    private func extractSuspicionScore(from alert: MemoryAlert) -> Double? {
        guard let metadata = alert.metadata,
              let suspicionStr = metadata["suspicion_score"],
              let suspicion = Double(suspicionStr) else {
            return nil
        }
        return suspicion
    }
}

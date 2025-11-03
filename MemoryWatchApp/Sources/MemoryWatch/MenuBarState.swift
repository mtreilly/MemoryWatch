import Foundation
import Combine

@MainActor
public final class MenuBarState: ObservableObject {
    public struct Snapshot {
        public let timestamp: Date
        public let metrics: SystemMetrics
        public let topProcess: ProcessInfo?
        public let topLeakSuspect: LeakSuspect?
        public let recentAlerts: [MemoryAlert]
        public let diagnosticHints: [DiagnosticSuggestion]
        public let notificationPreferences: NotificationPreferences
        public let isQuietHours: Bool
        public let systemAlerts: [MemoryAlert]
    }

    private let metricsProvider: () -> SystemMetrics
    private let processProvider: () -> [ProcessInfo]
    private let dateProvider: () -> Date
    private let historyLoader: (() async -> [SnapshotHistoryPoint])?
    private let preferencesLoader: () async -> NotificationPreferences
    private var notificationPreferences: NotificationPreferences
    private var lastPreferencesLoad: Date = .distantPast
    private let preferencesReloadInterval: TimeInterval = 120

    @Published public private(set) var snapshot: Snapshot
    @Published public private(set) var historyPoints: [SnapshotHistoryPoint] = []

    public init(metricsProvider: @escaping () -> SystemMetrics = SystemMetrics.current,
                processProvider: @escaping () -> [ProcessInfo] = { ProcessCollector.getAllProcessesWithCPU(minMemoryMB: 50) },
                dateProvider: @escaping () -> Date = { Date() },
                preferencesLoader: @escaping () async -> NotificationPreferences = { await NotificationPreferencesStore.load() },
                historyLoader: (() async -> [SnapshotHistoryPoint])? = nil) {
        self.metricsProvider = metricsProvider
        self.processProvider = processProvider
        self.dateProvider = dateProvider
        self.historyLoader = historyLoader
        self.preferencesLoader = preferencesLoader
        self.notificationPreferences = .default

        let initialMetrics = metricsProvider()
        let initialProcesses = processProvider()
        let initialTimestamp = dateProvider()
        let initialSystemAlerts: [MemoryAlert] = []
        snapshot = Snapshot(
            timestamp: initialTimestamp,
            metrics: initialMetrics,
            topProcess: initialProcesses.first,
            topLeakSuspect: nil,
            recentAlerts: [],
            diagnosticHints: [],
            notificationPreferences: notificationPreferences,
            isQuietHours: notificationPreferences.isQuietHours(now: initialTimestamp),
            systemAlerts: initialSystemAlerts
        )

        if let historyLoader {
            Task { [historyLoader] in
                let points = await historyLoader()
                await MainActor.run { [weak self] in
                    self?.historyPoints = points
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.reloadPreferences()
        }
    }

    public func refresh(processMonitor: ProcessMonitor?) {
        let now = dateProvider()
        maybeReloadPreferences(now: now)
        let metrics = metricsProvider()
        let processes = processProvider()
        let topProcess = processes.first

        let topLeak = processMonitor?.getLeakSuspects(minLevel: .medium).first

        let alerts = processMonitor?.getRecentAlerts(count: 10) ?? []

        var hints: [DiagnosticSuggestion] = alerts.compactMap { alert in
            guard alert.type == .diagnosticHint else { return nil }
            let meta = alert.metadata ?? [:]
            let title = meta["title"] ?? "Diagnostic Hint"
            let command = meta["command"] ?? alert.message
            let note = meta["note"]
            let path = meta["artifact_path"]
            return DiagnosticSuggestion(title: title, command: command, note: note, artifactPath: path)
        }

        if hints.isEmpty, let leak = topLeak {
            let latest = processMonitor?.latestSnapshot(for: leak.pid)
            let leakName = latest?.name ?? leak.name
            let path = latest?.executablePath
            hints = RuntimeDiagnostics.suggestions(pid: leak.pid, name: leakName, executablePath: path)
        }

        snapshot = Snapshot(
            timestamp: now,
            metrics: metrics,
            topProcess: topProcess,
            topLeakSuspect: topLeak,
            recentAlerts: alerts,
            diagnosticHints: hints,
            notificationPreferences: notificationPreferences,
            isQuietHours: notificationPreferences.isQuietHours(now: now),
            systemAlerts: MenuBarState.systemAlerts(from: alerts)
        )

        if let historyLoader {
            Task { [historyLoader] in
                let points = await historyLoader()
                await MainActor.run { [weak self] in
                    self?.historyPoints = points
                }
            }
        }
    }

    private func maybeReloadPreferences(now: Date) {
        if now.timeIntervalSince(lastPreferencesLoad) < preferencesReloadInterval {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.reloadPreferences()
        }
    }

    private func applyPreferences(_ prefs: NotificationPreferences) {
        notificationPreferences = prefs
        lastPreferencesLoad = Date()
        let current = snapshot
        snapshot = Snapshot(
            timestamp: current.timestamp,
            metrics: current.metrics,
            topProcess: current.topProcess,
            topLeakSuspect: current.topLeakSuspect,
            recentAlerts: current.recentAlerts,
            diagnosticHints: current.diagnosticHints,
            notificationPreferences: prefs,
            isQuietHours: prefs.isQuietHours(now: current.timestamp),
            systemAlerts: MenuBarState.systemAlerts(from: current.recentAlerts)
        )
    }

    private static func systemAlerts(from alerts: [MemoryAlert]) -> [MemoryAlert] {
        alerts.filter { alert in
            alert.type == .systemPressure || alert.type == .highSwap || alert.type == .datastoreWarning
        }
    }

    public func reloadPreferences() async {
        let prefs = await preferencesLoader()
        applyPreferences(prefs)
    }
}

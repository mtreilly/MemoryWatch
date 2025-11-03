import SwiftUI
import Combine
import AppKit
import UserNotifications
#if canImport(Charts)
import Charts
#endif
import MemoryWatchCore

@main
struct MemoryWatchMenuBarApp: App {
    @StateObject private var state: MenuBarState
    private let monitor: ProcessMonitor?
    private let historyProvider: SnapshotHistoryProvider?
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init() {
        try? MemoryWatchPaths.ensureDirectoriesExist()
        MemoryWatchPaths.migrateLegacyFiles()
        if let store = try? SQLiteStore(url: MemoryWatchPaths.databaseFile) {
            let monitor = ProcessMonitor(store: store)
            try? monitor.loadState(from: MemoryWatchPaths.stateFile)
            self.monitor = monitor
            let provider = SnapshotHistoryProvider(store: store, limit: 72)
            self.historyProvider = provider
            _state = StateObject(wrappedValue: MenuBarState(historyLoader: {
                await provider.loadHistory()
            }))
        } else {
            self.monitor = nil
            self.historyProvider = nil
            _state = StateObject(wrappedValue: MenuBarState())
        }

        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        registerNotificationCategories()
    }

    var body: some Scene {
        MenuBarExtra("MemoryWatch", systemImage: "memorychip") {
            MenuBarContentView(state: state,
                               monitor: monitor,
                               refreshTimer: refreshTimer)
                .frame(width: 320)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
        }
        .menuBarExtraStyle(.window)
    }

    private func registerNotificationCategories() {
        let runAction = UNNotificationAction(identifier: NotificationDelegate.runDiagnosticsAction,
                                             title: "Run Diagnostics",
                                             options: [])
        let category = UNNotificationCategory(identifier: NotificationDelegate.leakCategory,
                                              actions: [runAction],
                                              intentIdentifiers: [],
                                              options: .customDismissAction)
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

struct SystemAlertsView: View {
    let alerts: [MemoryWatchCore.MemoryAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System Alerts")
                .font(.subheadline)
                .bold()
            ForEach(Array(alerts.prefix(3).enumerated()), id: \.0) { _, alert in
                SystemAlertRow(alert: alert)
            }
        }
    }
}

struct SystemAlertRow: View {
    let alert: MemoryWatchCore.MemoryAlert

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .bold()
            Text(alert.message)
                .font(.caption2)
            Text(Self.timeFormatter.string(from: alert.timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch alert.type {
        case .systemPressure:
            return "Memory Pressure"
        case .highSwap:
            return "Swap Usage"
        case .datastoreWarning:
            return "Datastore"
        default:
            return "Alert"
        }
    }
}

struct SystemAlertBanner: View {
    let alert: MemoryWatchCore.MemoryAlert

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .bold()
                Text(alert.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: String {
        switch alert.type {
        case .systemPressure:
            return "Memory pressure critical"
        case .highSwap:
            return "Swap usage high"
        case .datastoreWarning:
            return "Datastore maintenance required"
        default:
            return "System alert"
        }
    }

    private var iconName: String {
        switch alert.type {
        case .systemPressure:
            return "exclamationmark.triangle.fill"
        case .highSwap:
            return "externaldrive.fill.badge.exclamationmark"
        case .datastoreWarning:
            return "internaldrive.fill.trianglebadge.exclamationmark"
        default:
            return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch alert.type {
        case .systemPressure:
            return .red
        case .highSwap:
            return .orange
        case .datastoreWarning:
            return .yellow
        default:
            return .yellow
        }
    }
}

struct QuietHoursBadge: View {
    let description: String?
    let allowNotifications: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "moon.fill")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quiet Hours")
                    .font(.caption)
                    .bold()
                if let description {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(allowNotifications ? "Notifications allowed" : "Notifications paused")
                    .font(.caption2)
                    .foregroundStyle(allowNotifications ? .green : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct NotificationPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var leakNotificationsEnabled: Bool
    @State private var pressureNotificationsEnabled: Bool
    @State private var allowDuringQuietHours: Bool
    @State private var quietHoursEnabled: Bool
    @State private var timezoneIdentifier: String
    @State private var quietStartDate: Date
    @State private var quietEndDate: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    let onSave: (NotificationPreferences) async throws -> Void

    private static let calendar = Calendar(identifier: .gregorian)

    init(preferences: NotificationPreferences, onSave: @escaping (NotificationPreferences) async throws -> Void) {
        self.onSave = onSave
        _leakNotificationsEnabled = State(initialValue: preferences.leakNotificationsEnabled)
        _pressureNotificationsEnabled = State(initialValue: preferences.pressureNotificationsEnabled)
        _allowDuringQuietHours = State(initialValue: preferences.allowInterruptionsDuringQuietHours)
        let quiet = preferences.quietHours ?? NotificationPreferences.QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)
        _quietHoursEnabled = State(initialValue: preferences.quietHours != nil)
        _timezoneIdentifier = State(initialValue: quiet.timezoneIdentifier)
        _quietStartDate = State(initialValue: NotificationPreferencesSheet.date(from: quiet.startMinutes, timezone: quiet.timezoneIdentifier))
        _quietEndDate = State(initialValue: NotificationPreferencesSheet.date(from: quiet.endMinutes, timezone: quiet.timezoneIdentifier))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notification Preferences")
                .font(.headline)

            Toggle("Leak alerts", isOn: $leakNotificationsEnabled)
                .accessibilityLabel("Leak alerts toggle")
                .accessibilityHint("Enable or disable notifications for detected memory leaks")
            Toggle("System pressure / swap alerts", isOn: $pressureNotificationsEnabled)
                .accessibilityLabel("System pressure alerts toggle")
                .accessibilityHint("Enable or disable notifications for memory pressure and swap usage")

            Divider()

            Toggle("Enable quiet hours", isOn: $quietHoursEnabled)
                .accessibilityLabel("Quiet hours toggle")
                .accessibilityHint("Enable or disable quiet hours scheduling")

            if quietHoursEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        DatePicker("Start", selection: $quietStartDate, displayedComponents: .hourAndMinute)
                            .accessibilityLabel("Quiet hours start time")
                            .accessibilityHint("Set the time when quiet hours begin")
                        DatePicker("End", selection: $quietEndDate, displayedComponents: .hourAndMinute)
                            .accessibilityLabel("Quiet hours end time")
                            .accessibilityHint("Set the time when quiet hours end")
                    }
                    TextField("Time zone", text: $timezoneIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Timezone field")
                        .accessibilityHint("Enter a timezone identifier for quiet hours scheduling")
                    Toggle("Allow notifications during quiet hours", isOn: $allowDuringQuietHours)
                        .toggleStyle(.switch)
                        .accessibilityLabel("Allow interruptions during quiet hours")
                        .accessibilityHint("When enabled, important notifications can interrupt quiet hours")
                }
                .padding(.leading, 4)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .accessibilityLabel("Error message")
                    .accessibilityValue(errorMessage)
            }

            HStack {
                Button("Reset to Defaults") {
                    applyDefaults()
                }
                .accessibilityLabel("Reset to defaults")
                .accessibilityHint("Restore all settings to their default values")
                .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .accessibilityLabel("Cancel")
                .accessibilityHint("Close preferences without saving changes")
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    Task { await persistChanges() }
                }
                .accessibilityLabel("Save preferences")
                .accessibilityHint("Save changes and close preferences")
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 320, maxWidth: 500)
    }

    private func persistChanges() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        do {
            let preferences = buildPreferences()
            try await onSave(preferences)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func buildPreferences() -> NotificationPreferences {
        let quietHours: NotificationPreferences.QuietHours?
        if quietHoursEnabled {
            let start = NotificationPreferencesSheet.minutes(from: quietStartDate, timezone: timezoneIdentifier)
            let end = NotificationPreferencesSheet.minutes(from: quietEndDate, timezone: timezoneIdentifier)
            quietHours = NotificationPreferences.QuietHours(startMinutes: start, endMinutes: end, timezoneIdentifier: timezoneIdentifier)
        } else {
            quietHours = nil
        }
        return NotificationPreferences(
            quietHours: quietHours,
            leakNotificationsEnabled: leakNotificationsEnabled,
            pressureNotificationsEnabled: pressureNotificationsEnabled,
            allowInterruptionsDuringQuietHours: allowDuringQuietHours
        )
    }

    private func applyDefaults() {
        let defaults = NotificationPreferences.default
        leakNotificationsEnabled = defaults.leakNotificationsEnabled
        pressureNotificationsEnabled = defaults.pressureNotificationsEnabled
        allowDuringQuietHours = defaults.allowInterruptionsDuringQuietHours
        quietHoursEnabled = defaults.quietHours != nil
        let quiet = defaults.quietHours ?? NotificationPreferences.QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)
        timezoneIdentifier = quiet.timezoneIdentifier
        quietStartDate = NotificationPreferencesSheet.date(from: quiet.startMinutes, timezone: quiet.timezoneIdentifier)
        quietEndDate = NotificationPreferencesSheet.date(from: quiet.endMinutes, timezone: quiet.timezoneIdentifier)
    }

    private static func date(from minutes: Int, timezone: String) -> Date {
        var calendar = NotificationPreferencesSheet.calendar
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let base = calendar.startOfDay(for: Date())
        let hrs = minutes / 60
        let mins = minutes % 60
        return calendar.date(bySettingHour: hrs, minute: mins, second: 0, of: base) ?? base
    }

    private static func minutes(from date: Date, timezone: String) -> Int {
        var calendar = NotificationPreferencesSheet.calendar
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

@MainActor
final class NotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    static let leakCategory = "MEMWATCH_LEAK"
    static let runDiagnosticsAction = "MEMWATCH_RUN_DIAGNOSTICS"

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        handleNotificationResponse(response)
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.notification.request.content.categoryIdentifier == Self.leakCategory else { return }

        let pidValue: Int32?
        if let pidNumber = response.notification.request.content.userInfo["pid"] as? Int32 {
            pidValue = pidNumber
        } else if let pidString = response.notification.request.content.userInfo["pid"] as? String,
                  let pid = Int32(pidString) {
            pidValue = pid
        } else {
            pidValue = nil
        }

        guard let pid = pidValue else { return }

        if response.actionIdentifier == Self.runDiagnosticsAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DiagnosticsLauncher.launchDiagnostics(for: pid)
        }
    }
}

enum DiagnosticsLauncher {
    static func launchDiagnostics(for pid: Int32) {
        let script = "tell application \"Terminal\" to do script \"memwatch diagnostics \(pid)\""
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        try? process.run()
    }

    static func viewStatus() {
        let script = "tell application \"Terminal\" to do script \"memwatch status\""
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        try? process.run()
    }
}

struct MenuBarContentView: View {
    @ObservedObject var state: MenuBarState
    let monitor: ProcessMonitor?
    let refreshTimer: Publishers.Autoconnect<Timer.TimerPublisher>
    @State private var notificationsAuthorized = false
    @State private var lastNotifiedPid: Int32?
    @State private var selectedTab: Tab = .overview
    @State private var selectedHistoryPoint: SnapshotHistoryPoint?
    @State private var deliveredAlertHistory: [String: Date] = DeliveredAlertHistoryStore.load()
    @State private var showPreferences = false

    private var reportsURL: URL { MemoryWatchPaths.reportsDir }
    private var samplesURL: URL { MemoryWatchPaths.samplesDir }
    private var logsURL: URL { MemoryWatchPaths.logsDir }

    var body: some View {
        let snapshot = state.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(snapshot: snapshot)
            if snapshot.isQuietHours {
                QuietHoursBadge(description: snapshot.notificationPreferences.quietHoursDescription(),
                                allowNotifications: snapshot.notificationPreferences.allowInterruptionsDuringQuietHours)
            }
            if let primaryAlert = snapshot.systemAlerts.first {
                SystemAlertBanner(alert: primaryAlert)
            }
            Picker("View", selection: $selectedTab) {
                Text("Overview").tag(Tab.overview)
                Text("History").tag(Tab.history)
                Text("Diagnostics").tag(Tab.diagnostics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Tab selector")
            .accessibilityHint("Choose between Overview, History, or Diagnostics view")

            switch selectedTab {
            case .overview:
                OverviewSection(snapshot: snapshot)
            case .history:
#if canImport(Charts)
                if #available(macOS 13.0, *), !state.historyPoints.isEmpty {
                    HistorySectionView(points: state.historyPoints,
                                       selectedPoint: $selectedHistoryPoint,
                                       onSelect: { point in handleHistorySelection(point) })
                    if let detail = selectedHistoryPoint ?? state.historyPoints.last {
                        HistoryPointDetailView(point: detail,
                                               onRevealReports: { openReportsDirectory() },
                                               onRevealLogs: { NSWorkspace.shared.open(logsURL) },
                                               onRevealSamples: { NSWorkspace.shared.open(samplesURL) },
                                               onLaunchDiagnostics: { runDiagnostics(for: $0) })
                    }
                } else {
                    HistoryUnavailableView()
                }
#else
                HistoryUnavailableView()
#endif
            case .diagnostics:
                DiagnosticsSection(snapshot: snapshot,
                                   historyPoints: state.historyPoints,
                                   runDiagnostics: { launchDiagnostics() },
                                   reportsURL: reportsURL,
                                   samplesURL: samplesURL,
                                   logsURL: logsURL,
                                   openPreferences: { showPreferences = true })
            }
        }
        .onAppear {
            state.refresh(processMonitor: monitor)
            requestNotificationAuthorization()
        }
        .onReceive(refreshTimer) { _ in
            state.refresh(processMonitor: monitor)
            evaluateNotifications(snapshot: state.snapshot)
        }
        .onChange(of: snapshot.topLeakSuspect?.pid) { _ in
            evaluateNotifications(snapshot: state.snapshot)
        }
        .onChange(of: snapshot.notificationPreferences) { _ in
            evaluateNotifications(snapshot: state.snapshot)
        }
        .sheet(isPresented: $showPreferences) {
            NotificationPreferencesSheet(
                preferences: state.snapshot.notificationPreferences,
                onSave: { newPreferences in
                    try await NotificationPreferencesStore.save(newPreferences)
                    await state.reloadPreferences()
                }
            )
            .frame(width: 360)
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                notificationsAuthorized = granted
            }
        }
    }

    private func evaluateNotifications(snapshot: MenuBarState.Snapshot) {
        guard notificationsAuthorized else { return }

        pruneDeliveredAlerts(retainingRecentSeconds: 6 * 3600)

        let preferences = snapshot.notificationPreferences
        if !preferences.leakNotificationsEnabled {
            lastNotifiedPid = nil
        }

        let quietSuppressed = snapshot.isQuietHours && !preferences.allowInterruptionsDuringQuietHours

        if preferences.leakNotificationsEnabled,
           !quietSuppressed,
           let suspect = snapshot.topLeakSuspect,
           (suspect.suspicionLevel == .high || suspect.suspicionLevel == .critical) {
            let leakKey = leakSignature(for: suspect.pid)
            if deliveredAlertHistory[leakKey] == nil {
                lastNotifiedPid = suspect.pid

                let content = UNMutableNotificationContent()
                content.title = "MemoryWatch: \(suspect.suspicionLevel.rawValue) leak"
                content.body = "\(suspect.name) grew \(String(format: "%.0f", suspect.growthMB))MB (\(String(format: "%.1f", suspect.growthRate)) MB/hr)"
                content.sound = .default
                content.categoryIdentifier = NotificationDelegate.leakCategory
                content.userInfo = ["pid": suspect.pid]

                let identifier = "memwatch.leak.\(suspect.pid)"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

                deliveredAlertHistory[leakKey] = Date()
                DeliveredAlertHistoryStore.save(deliveredAlertHistory)
            }
        }

        if preferences.pressureNotificationsEnabled && !quietSuppressed {
            snapshot.systemAlerts.forEach { deliverSystemAlertIfNeeded($0) }
        }
    }

    private func pruneDeliveredAlerts(retainingRecentSeconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-retainingRecentSeconds)
        var changed = false
        deliveredAlertHistory = deliveredAlertHistory.filter { key, value in
            if value > cutoff {
                return true
            } else {
                changed = true
                return false
            }
        }
        if deliveredAlertHistory.count > 80 {
            let sortedKeys = deliveredAlertHistory.sorted { lhs, rhs in lhs.value > rhs.value }.map { $0.key }
            for key in sortedKeys.dropFirst(60) {
                deliveredAlertHistory.removeValue(forKey: key)
                changed = true
            }
        }
        if changed {
            DeliveredAlertHistoryStore.save(deliveredAlertHistory)
        }
    }

    private func deliverSystemAlertIfNeeded(_ alert: MemoryWatchCore.MemoryAlert) {
        let signature = systemAlertSignature(for: alert)
        if deliveredAlertHistory[signature] != nil { return }
        deliveredAlertHistory[signature] = Date()
        DeliveredAlertHistoryStore.save(deliveredAlertHistory)

        let content = UNMutableNotificationContent()
        switch alert.type {
        case .systemPressure:
            content.title = "Memory pressure critical"
        case .highSwap:
            content.title = "Swap usage high"
        default:
            content.title = "MemoryWatch alert"
        }
        content.body = alert.message
        content.sound = .default

        let identifier = "memwatch.system.\(signature)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func systemAlertSignature(for alert: MemoryWatchCore.MemoryAlert) -> String {
        let timestamp = alert.timestamp.timeIntervalSince1970
        return "\(alert.type.rawValue)|\(String(format: "%.0f", timestamp))|\(alert.message)"
    }

    private func leakSignature(for pid: Int32) -> String {
        "LEAK|\(pid)"
    }

    private func launchDiagnostics() {
        guard let suspect = state.snapshot.topLeakSuspect else { return }
        DiagnosticsLauncher.launchDiagnostics(for: suspect.pid)
    }

    private func runDiagnostics(for process: MemoryWatchCore.ProcessInfo) {
        DiagnosticsLauncher.launchDiagnostics(for: process.pid)
    }

    private func openReportsDirectory() {
        NSWorkspace.shared.open(reportsURL)
    }

    private func handleHistorySelection(_ point: SnapshotHistoryPoint) {
        selectedHistoryPoint = point
    }

    private enum Tab: Hashable {
        case overview
        case history
        case diagnostics
    }
}

struct HeaderView: View {
    let snapshot: MenuBarState.Snapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MemoryWatch")
                    .font(.headline)
                Text(snapshot.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PressureIndicator(pressure: snapshot.metrics.pressure)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MemoryWatch status")
    }
}

struct PressureIndicator: View {
    let pressure: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(pressure)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System memory pressure")
        .accessibilityValue(pressureDescription)
    }

    private var pressureDescription: String {
        switch pressure {
        case "Normal": return "Normal, system has sufficient memory available"
        case "Warning": return "Warning, system memory usage is elevated"
        case "Critical": return "Critical, system is experiencing high memory pressure"
        default: return pressure
        }
    }

    private var iconName: String {
        switch pressure {
        case "Normal": return "checkmark.circle.fill"
        case "Warning": return "exclamationmark.circle.fill"
        case "Critical": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch pressure {
        case "Normal": return .green
        case "Warning": return .orange
        case "Critical": return .red
        default: return .gray
        }
    }
}

struct MetricsView: View {
    let metrics: SystemMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System")
                .font(.subheadline)
                .bold()
            MetricRow(label: "Used", value: String(format: "%.1f GB", metrics.usedMemoryGB),
                      accessibilityHint: "Memory currently in use")
            MetricRow(label: "Free", value: String(format: "%.1f GB", metrics.freeMemoryGB),
                      accessibilityHint: "Available memory")
            MetricRow(label: "Swap", value: String(format: "%.0f / %.0f MB", metrics.swapUsedMB, metrics.swapTotalMB),
                      accessibilityHint: "Swap memory used out of total")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System memory metrics")
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    let accessibilityHint: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityHint(accessibilityHint)
    }
}

struct TopProcessView: View {
    let process: MemoryWatchCore.ProcessInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top Process")
                .font(.subheadline)
                .bold()
            Text(process.name)
                .font(.body)
            MetricRow(label: "Memory", value: String(format: "%.0f MB", process.memoryMB),
                      accessibilityHint: "Memory usage by this process")
            MetricRow(label: "CPU", value: String(format: "%.1f%%", process.cpuPercent),
                      accessibilityHint: "CPU usage percentage")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top process: \(process.name)")
    }
}

struct LeakSuspectView: View {
    let suspect: MemoryWatchCore.LeakSuspect

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Leak Suspect")
                .font(.subheadline)
                .bold()
            Text(suspect.name)
                .font(.body)
            MetricRow(label: "Growth", value: String(format: "%.0f MB", suspect.growthMB),
                      accessibilityHint: "Total memory growth detected")
            MetricRow(label: "Rate", value: String(format: "%.1f MB/hr", suspect.growthRate),
                      accessibilityHint: "Rate of memory growth per hour")
            MetricRow(label: "Level", value: suspect.suspicionLevel.rawValue,
                      accessibilityHint: "Leak severity level")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory leak suspect: \(suspect.name)")
        .accessibilityValue("Level: \(suspect.suspicionLevel.rawValue)")
    }
}

struct DiagnosticHintList: View {
    let hints: [MemoryWatchCore.DiagnosticSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.subheadline)
                .bold()
            ForEach(Array(hints.enumerated()), id: \.0) { _, hint in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.title)
                        .font(.caption)
                        .bold()
                    Text(hint.command)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let path = hint.artifactPath {
                        let expanded = NSString(string: path).expandingTildeInPath
                        let url = URL(fileURLWithPath: expanded)
                        if FileManager.default.fileExists(atPath: url.path) {
                            Link("Open artifact", destination: url)
                                .font(.caption2)
                        } else {
                            Text("Artifact missing: \(expanded)")
                                .font(.caption2)
                                .foregroundStyle(.pink)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct MenuBarActionsView: View {
    let reportsURL: URL
    let samplesURL: URL
    let logsURL: URL
    let runDiagnostics: () -> Void
    let viewStatus: () -> Void
    let openPreferences: () -> Void
    let snapshot: MenuBarState.Snapshot?
    let historyPoints: [SnapshotHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Actions")
                .font(.subheadline)
                .bold()
            Link("Open Reports", destination: reportsURL)
                .font(.caption)
                .accessibilityLabel("Open reports folder")
                .accessibilityHint("Shows memory analysis reports")
            Link("Open Samples", destination: samplesURL)
                .font(.caption)
                .accessibilityLabel("Open samples folder")
                .accessibilityHint("Shows diagnostic sample files")
            Link("Open Logs", destination: logsURL)
                .font(.caption)
                .accessibilityLabel("Open logs folder")
                .accessibilityHint("Shows application logs")

            Button("Export Snapshot (JSON)") { exportSnapshot() }
                .font(.caption)
                .accessibilityLabel("Export snapshot")
                .accessibilityHint("Save current memory state to JSON file")
                .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("Export History (CSV)") { exportHistory() }
                .font(.caption)
                .accessibilityLabel("Export history")
                .accessibilityHint("Save memory history to CSV file for analysis")
                .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("View Status") { viewStatus() }
                .font(.caption)
                .accessibilityLabel("View status")
                .accessibilityHint("Opens Terminal to show detailed status")
                .keyboardShortcut("s", modifiers: .command)
            Button("Run Diagnostics") { runDiagnostics() }
                .font(.caption)
                .accessibilityLabel("Run diagnostics")
                .accessibilityHint("Executes diagnostic procedures for the suspected process")
                .keyboardShortcut("d", modifiers: .command)
            Button("Notification Preferences…") { openPreferences() }
                .font(.caption)
                .accessibilityLabel("Notification preferences")
                .accessibilityHint("Configure notification settings and quiet hours")
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func exportSnapshot() {
        guard let snapshot else { return }
        guard let jsonData = SnapshotExporter.exportSnapshotAsJSON(snapshot) else { return }

        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: snapshot.timestamp)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let filename = "MemoryWatch_Snapshot_\(timestamp).json"

        _ = SnapshotExporter.saveAndReveal(data: jsonData, filename: filename)
    }

    private func exportHistory() {
        guard let csvData = SnapshotExporter.exportHistoryAsCSV(historyPoints) else { return }

        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let filename = "MemoryWatch_History_\(timestamp).csv"

        _ = SnapshotExporter.saveAndReveal(data: csvData, filename: filename)
    }
}

#if canImport(Charts)
@available(macOS 13.0, *)
struct HistorySectionView: View {
    let points: [SnapshotHistoryPoint]
    @Binding var selectedPoint: SnapshotHistoryPoint?
    let onSelect: (SnapshotHistoryPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Memory")
                .font(.subheadline)
                .bold()
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used GB", point.usedMemoryGB)
                    )
                    .foregroundStyle(by: .value("Series", "Used Memory"))
                }
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Swap GB", point.swapUsedMB / 1024.0)
                    )
                    .foregroundStyle(by: .value("Series", "Swap Usage"))
                }
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("SSD Wear (GB)", point.ssdWearMB / 1024.0)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(Color.purple.opacity(0.18))
                }
                ForEach(points) { point in
                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used GB", point.usedMemoryGB)
                    )
                    .symbolSize(point.id == selectedPoint?.id ? 80 : 30)
                    .foregroundStyle(point.id == selectedPoint?.id ? Color.accentColor : Color.blue.opacity(0.6))
                }
            }
            .chartLegend(position: .bottom, spacing: 8)
            .chartForegroundStyleScale([
                "Used Memory": Color.blue,
                "Swap Usage": Color.orange
            ])
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let origin = geometry[proxy.plotAreaFrame].origin
                                    let location = CGPoint(
                                        x: value.location.x - origin.x,
                                        y: value.location.y - origin.y
                                    )
                                    if let time: Date = proxy.value(atX: location.x, as: Date.self) {
                                        if let nearest = points.min(by: { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }) {
                                            if nearest.id != selectedPoint?.id {
                                                selectedPoint = nearest
                                                onSelect(nearest)
                                            }
                                        }
                                    }
                                }
                        )
                }
            }
            .chartXAxis(.automatic)
            .chartYAxisLabel(position: .trailing) {
                Text("GB")
                    .font(.caption2)
            }
            .frame(height: 150)
            Text("Tap a point to inspect swap churn, SSD wear estimates, and jump to diagnostics for the recorded top process.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

struct OverviewSection: View {
    let snapshot: MenuBarState.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricsView(metrics: snapshot.metrics)
            if let topProcess = snapshot.topProcess {
                Divider()
                TopProcessView(process: topProcess)
            }
            if let suspect = snapshot.topLeakSuspect {
                Divider()
                LeakSuspectView(suspect: suspect)
            }
            if !snapshot.systemAlerts.isEmpty {
                Divider()
                SystemAlertsView(alerts: snapshot.systemAlerts)
            }
        }
        .dynamicTypeSize(.xSmall ... .xxxLarge)
    }
}

struct DiagnosticsSection: View {
    let snapshot: MenuBarState.Snapshot
    let historyPoints: [SnapshotHistoryPoint]
    let runDiagnostics: () -> Void
    let reportsURL: URL
    let samplesURL: URL
    let logsURL: URL
    let openPreferences: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.diagnosticHints.isEmpty {
                DiagnosticHintList(hints: snapshot.diagnosticHints)
            } else {
                Text("No diagnostic hints yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            MenuBarActionsView(
                reportsURL: reportsURL,
                samplesURL: samplesURL,
                logsURL: logsURL,
                runDiagnostics: runDiagnostics,
                viewStatus: { DiagnosticsLauncher.viewStatus() },
                openPreferences: openPreferences,
                snapshot: snapshot,
                historyPoints: historyPoints
            )
        }
    }
}

struct HistoryUnavailableView: View {
    var body: some View {
        Text("History unavailable")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct HistoryPointDetailView: View {
    let point: SnapshotHistoryPoint
    let onRevealReports: () -> Void
    let onRevealLogs: () -> Void
    let onRevealSamples: () -> Void
    let onLaunchDiagnostics: (MemoryWatchCore.ProcessInfo) -> Void

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: point.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Snapshot \(formattedTime)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                metricPill(title: "Used", value: String(format: "%.2f GB", point.usedMemoryGB))
                metricPill(title: "Swap", value: String(format: "%.0f MB", point.swapUsedMB))
                metricPill(title: "SSD Writes", value: String(format: "%.2f GB", point.ssdWearMB / 1024.0))
            }

            if let process = point.topProcess {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Process")
                        .font(.caption)
                        .bold()
                    Text(process.name)
                        .font(.caption)
                    if let path = process.executablePath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        Text(String(format: "%.0f MB", process.memoryMB))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%% CPU", process.cpuPercent))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if process.pid > 0 {
                        Button("Run diagnostics") {
                            onLaunchDiagnostics(process)
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text("No process sample captured for this snapshot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Open reports") { onRevealReports() }
                Button("Open samples") { onRevealSamples() }
                Button("Open logs") { onRevealLogs() }
            }
            .font(.caption)
        }
        .padding(.top, 8)
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

import Foundation
import Dispatch

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public struct QuietHours: Codable, Equatable, Sendable {
        public var startMinutes: Int
        public var endMinutes: Int
        public var timezoneIdentifier: String

        public init(startMinutes: Int, endMinutes: Int, timezoneIdentifier: String = TimeZone.current.identifier) {
            self.startMinutes = QuietHours.clampMinutes(startMinutes)
            self.endMinutes = QuietHours.clampMinutes(endMinutes)
            self.timezoneIdentifier = timezoneIdentifier
        }

        private static func clampMinutes(_ value: Int) -> Int {
            let minutes = value % (24 * 60)
            return minutes >= 0 ? minutes : minutes + 24 * 60
        }

        public func contains(_ date: Date, calendar baseCalendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
            guard startMinutes != endMinutes else { return false }
            var calendar = baseCalendar
            if let zone = TimeZone(identifier: timezoneIdentifier) {
                calendar.timeZone = zone
            }
            let components = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            if startMinutes < endMinutes {
                return minutes >= startMinutes && minutes < endMinutes
            } else {
                return minutes >= startMinutes || minutes < endMinutes
            }
        }

        public func description() -> String {
            let startString = QuietHours.format(minutes: startMinutes)
            let endString = QuietHours.format(minutes: endMinutes)
            let abbreviation = TimeZone(identifier: timezoneIdentifier)?.abbreviation() ?? timezoneIdentifier
            return "\(startString)–\(endString) \(abbreviation)"
        }

        private static func format(minutes: Int) -> String {
            let hrs = (minutes / 60) % 24
            let mins = minutes % 60
            return String(format: "%02d:%02d", hrs, mins)
        }
    }

    public var quietHours: QuietHours?
    public var leakNotificationsEnabled: Bool
    public var pressureNotificationsEnabled: Bool
    public var allowInterruptionsDuringQuietHours: Bool
    public var updateCadenceSeconds: TimeInterval
    public var retentionWindowHours: Int

    public init(quietHours: QuietHours? = QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60),
                leakNotificationsEnabled: Bool = true,
                pressureNotificationsEnabled: Bool = true,
                allowInterruptionsDuringQuietHours: Bool = false,
                updateCadenceSeconds: TimeInterval = 30,
                retentionWindowHours: Int = 72) {
        self.quietHours = quietHours
        self.leakNotificationsEnabled = leakNotificationsEnabled
        self.pressureNotificationsEnabled = pressureNotificationsEnabled
        self.allowInterruptionsDuringQuietHours = allowInterruptionsDuringQuietHours
        self.updateCadenceSeconds = max(5, min(300, updateCadenceSeconds))  // Clamp between 5s and 5m
        self.retentionWindowHours = max(1, min(720, retentionWindowHours))  // Clamp between 1h and 30d
    }

    public static let `default` = NotificationPreferences()

    public func isQuietHours(now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let quietHours else { return false }
        return quietHours.contains(now, calendar: calendar)
    }

    public func quietHoursDescription() -> String? {
        quietHours?.description()
    }
}

private actor NotificationPreferencesCache {
    private var overrideURL: URL?
    private var cachedPreferences: NotificationPreferences = .default
    private var cachedModificationDate: Date?

    private var fileURL: URL {
        overrideURL ?? MemoryWatchPaths.dataDir.appendingPathComponent("notification_preferences.json")
    }

    func load() -> NotificationPreferences {
        let fm = FileManager.default
        let url = fileURL

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let modification = attrs[.modificationDate] as? Date {
            if cachedModificationDate == nil || modification > (cachedModificationDate ?? .distantPast) {
                if let data = try? Data(contentsOf: url) {
                    let decoder = JSONDecoder()
                    if let decoded = try? decoder.decode(NotificationPreferences.self, from: data) {
                        cachedPreferences = decoded
                    }
                }
                cachedModificationDate = modification
            }
        } else if !fm.fileExists(atPath: url.path) {
            cachedPreferences = .default
            cachedModificationDate = nil
        }

        return cachedPreferences
    }

    func save(_ preferences: NotificationPreferences) throws {
        try MemoryWatchPaths.ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: fileURL, options: .atomic)
        cachedPreferences = preferences
        cachedModificationDate = Date()
    }

    func reset() {
        cachedPreferences = .default
        cachedModificationDate = nil
    }

    func setOverrideURL(_ url: URL?) {
        overrideURL = url
        cachedPreferences = .default
        cachedModificationDate = nil
    }
}

public enum NotificationPreferencesStore {
    private static let cache = NotificationPreferencesCache()

    public static func load() async -> NotificationPreferences {
        await cache.load()
    }

    public static func save(_ preferences: NotificationPreferences) async throws {
        try await cache.save(preferences)
    }

    public static func loadSync(timeout: TimeInterval = 2) -> NotificationPreferences {
        let url = MemoryWatchPaths.dataDir.appendingPathComponent("notification_preferences.json")
        guard let data = try? Data(contentsOf: url) else {
            return .default
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(NotificationPreferences.self, from: data)) ?? .default
    }

    static func resetForTesting() async {
        await cache.reset()
    }

    static func setOverrideURLForTesting(_ url: URL?) async {
        await cache.setOverrideURL(url)
    }
}

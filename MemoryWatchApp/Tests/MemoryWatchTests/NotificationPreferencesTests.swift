import XCTest
@testable import MemoryWatchCore

final class NotificationPreferencesTests: XCTestCase {
    func testQuietHoursWrapAroundMidnight() throws {
        let quiet = NotificationPreferences.QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)
        var calendar = Calendar(identifier: .gregorian)
        let zone = try! XCTUnwrap(TimeZone(identifier: quiet.timezoneIdentifier))
        calendar.timeZone = zone

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = calendar.timeZone

        let evening = formatter.date(from: "2024-06-01 22:15")!
        XCTAssertTrue(quiet.contains(evening, calendar: calendar))

        let earlyMorning = formatter.date(from: "2024-06-02 06:30")!
        XCTAssertTrue(quiet.contains(earlyMorning, calendar: calendar))

        let midday = formatter.date(from: "2024-06-02 12:00")!
        XCTAssertFalse(quiet.contains(midday, calendar: calendar))
    }

    func testStorePersistsPreferences() async throws {
        await NotificationPreferencesStore.resetForTesting()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("prefs.json")
        await NotificationPreferencesStore.setOverrideURLForTesting(fileURL)

        var preferences = NotificationPreferences.default
        preferences.leakNotificationsEnabled = false
        preferences.allowInterruptionsDuringQuietHours = true
        preferences.quietHours = NotificationPreferences.QuietHours(startMinutes: 1 * 60, endMinutes: 2 * 60, timezoneIdentifier: "UTC")

        try await NotificationPreferencesStore.save(preferences)
        await NotificationPreferencesStore.resetForTesting()

        let loaded = await NotificationPreferencesStore.load()
        XCTAssertEqual(loaded, preferences)

        await NotificationPreferencesStore.setOverrideURLForTesting(nil)
    }
}

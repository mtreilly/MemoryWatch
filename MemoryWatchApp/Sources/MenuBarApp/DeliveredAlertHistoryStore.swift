import Foundation
import MemoryWatchCore

enum DeliveredAlertHistoryStore {
    private static var fileURL: URL {
        MemoryWatchPaths.stateDir.appendingPathComponent("menu_bar_alerts.json")
    }

    static func load() -> [String: Date] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    static func save(_ history: [String: Date]) {
        do {
            try MemoryWatchPaths.ensureDirectoriesExist()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best effort persistence; ignore failures for now.
        }
    }
}

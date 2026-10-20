import Foundation

struct PersistenceService {
    private static let appSupportDir: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TicketRadar", isDirectory: true)
        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir
    }()

    private static var ticketsFileURL: URL {
        appSupportDir.appendingPathComponent("tickets.json")
    }

    private static var settingsFileURL: URL {
        appSupportDir.appendingPathComponent("settings.json")
    }

    // MARK: - Tickets

    static func loadTickets() -> [WatchedTicket] {
        guard let data = try? Data(contentsOf: ticketsFileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WatchedTicket].self, from: data)) ?? []
    }

    static func saveTickets(_ tickets: [WatchedTicket]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tickets) else { return }
        try? data.write(to: ticketsFileURL, options: .atomic)
    }

    // MARK: - Settings

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFileURL) else {
            return .default
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? .default
    }

    static func saveSettings(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsFileURL, options: .atomic)
    }
}

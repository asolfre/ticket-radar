import Foundation

/// A whole-setup backup: every ticket and the settings, as one JSON file.
///
/// Export and import go through the File menu. A backup file is untrusted
/// input (it can be hand-edited), so `read` and `merge` bound and validate it;
/// everything here is pure so the self-check can test it without a
/// `TicketStore`, whose init reads the real data folder.
struct Backup: Codable {
    var version: Int
    var exportedAt: Date
    var tickets: [WatchedTicket]
    var settings: AppSettings

    /// Bump for any change older apps cannot read (e.g. a new enum case):
    /// they refuse a newer version instead of misreading it.
    static let currentVersion = 1
    static let maxBytes = 10_000_000

    // MARK: - Export

    static func export(tickets: [WatchedTicket], settings: AppSettings) throws -> Data {
        var settings = settings
        settings.customToolPath = nil // machine-specific; can show the home folder
        let data = try encoder.encode(Backup(version: currentVersion, exportedAt: Date(), tickets: tickets, settings: settings))
        guard data.count <= maxBytes else { throw BackupError.exportTooLarge }
        return data
    }

    // MARK: - Read

    /// Reads a backup file: regular files only (after resolving links), at most
    /// `maxBytes`. A symlink reports its own size and a FIFO blocks on open, so
    /// neither the URL's file size nor a plain `Data(contentsOf:)` is enough.
    static func read(_ url: URL) throws -> Data {
        let resolved = url.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BackupError.notAFile
        }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw BackupError.fileTooLarge }
        return data
    }

    // MARK: - Merge

    struct Result {
        var tickets: [WatchedTicket]
        var settings: AppSettings
        var summary: Summary
    }

    /// Adds what this Mac is missing and never overwrites what it has.
    static func merge(_ data: Data, into tickets: [WatchedTicket], settings: AppSettings) throws -> Result {
        struct VersionOnly: Decodable { let version: Int }
        guard let version = try? decoder.decode(VersionOnly.self, from: data).version else {
            throw BackupError.notABackup
        }
        guard version <= currentVersion else { throw BackupError.newerVersion }
        guard version == currentVersion,
              let backup = try? decoder.decode(Backup.self, from: data) else {
            throw BackupError.notABackup
        }

        var summary = Summary()
        var watched = Set(tickets.map { $0.ticketKey.uppercased() })
        var imported: [WatchedTicket] = []

        for ticket in backup.tickets {
            let key = ticket.ticketKey.uppercased()
            guard matches(key, ticketKeyPattern) else {
                summary.droppedKeys.append(ticket.ticketKey)
                continue
            }
            guard watched.insert(key).inserted else {
                summary.skipped += 1
                continue
            }
            let pullRequests = ticket.pullRequests.filter { isGitHubPRURL($0.url) }
            summary.droppedPRs += ticket.pullRequests.count - pullRequests.count

            // A new id: ids from a file cannot be trusted.
            var copy = WatchedTicket(
                ticketKey: key,
                title: ticket.title,
                lastRefreshed: ticket.lastRefreshed,
                knownPRURLs: ticket.knownPRURLs,
                isArchived: ticket.isArchived
            )
            if ticket.isArchived {
                // Archived tickets are never refreshed: keep their snapshot.
                copy.pullRequests = pullRequests
                copy.status = ticket.status
                summary.addedArchived += 1
            } else {
                // Refreshed right away; an old snapshot would only trigger
                // stale notifications from the next poll.
                summary.addedActive += 1
            }
            // searchPRURLs, ssoBlockedOrg and jiraLoginSite stay nil: the search
            // cache is reused when a search fails (one fetch per URL), and the
            // banners describe the exporting Mac and hold a command to paste.
            imported.append(copy)
        }

        var merged = settings
        mergeProjects(from: backup.settings, into: &merged, summary: &summary)
        restoreSettings(from: backup.settings, into: &merged, summary: &summary)

        return Result(tickets: tickets + TicketStore.migratePRURLs(imported), settings: merged, summary: summary)
    }

    /// Adds Projects entries this Mac lacks, in sorted prefix order so a file
    /// with both `data` and `DATA` always gives the same result.
    private static func mergeProjects(from backup: AppSettings, into settings: inout AppSettings, summary: inout Summary) {
        var orgs = settings.githubOwners ?? [:]
        var sites = settings.jiraSites ?? [:]

        for (prefix, value) in (backup.githubOwners ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let entry = projectEntry(prefix, value, isSite: false) else { summary.droppedMappings += 1; continue }
            if orgs[entry.prefix] == nil { orgs[entry.prefix] = entry.value; summary.addedMappings += 1 }
        }
        for (prefix, value) in (backup.jiraSites ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let entry = projectEntry(prefix, value, isSite: true) else { summary.droppedMappings += 1; continue }
            if sites[entry.prefix] == nil { sites[entry.prefix] = entry.value; summary.addedMappings += 1 }
        }
        settings.githubOwners = orgs.isEmpty ? nil : orgs
        settings.jiraSites = sites.isEmpty ? nil : sites
    }

    /// A Projects entry as Settings would store it, or nil when it is invalid
    /// or would change in the Settings text. Sites end up in a command the
    /// user can copy to Terminal, so values must look like a hostname or a
    /// GitHub org name.
    private static func projectEntry(_ prefix: String, _ value: String, isSite: Bool) -> (prefix: String, value: String)? {
        let prefix = prefix.trimmingCharacters(in: .whitespaces).uppercased()
        var value = value.trimmingCharacters(in: .whitespaces)
        if isSite { value = URL(string: value)?.host ?? value }
        guard matches(prefix, projectPrefixPattern),
              matches(value, isSite ? hostPattern : orgPattern) else { return nil }
        let text = AppSettings.formatProjectMap(orgs: isSite ? nil : [prefix: value], sites: isSite ? [prefix: value] : nil)
        let parsed = AppSettings.parseProjectMap(text)
        guard (isSite ? parsed.sites : parsed.orgs) == [prefix: value],
              (isSite ? parsed.orgs : parsed.sites).isEmpty else { return nil }
        return (prefix, value)
    }

    private static func restoreSettings(from backup: AppSettings, into settings: inout AppSettings, summary: inout Summary) {
        if (1...30).contains(backup.pollIntervalMinutes), backup.pollIntervalMinutes != settings.pollIntervalMinutes {
            settings.pollIntervalMinutes = backup.pollIntervalMinutes
            summary.restored.append("poll interval")
        }
        if backup.notificationsEnabled != settings.notificationsEnabled {
            settings.notificationsEnabled = backup.notificationsEnabled
            summary.restored.append("notifications")
        }
        // Only when this Mac has none: they decide where unmapped tickets go.
        if settings.normalizedJiraBaseURL == nil,
           let base = backup.normalizedJiraBaseURL, let url = URL(string: base),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, matches(host, hostPattern) {
            settings.jiraBaseURL = base
            summary.restored.append("Jira base URL")
        }
        if settings.normalizedGithubOwner == nil,
           let owner = backup.normalizedGithubOwner, matches(owner, orgPattern) {
            settings.githubOwner = owner
            summary.restored.append("default GitHub organization")
        }
    }

    // MARK: - Save

    enum SaveOutcome: Equatable { case saved, ticketsFailed, settingsFailed }

    /// Tickets first, then settings; settings are not attempted when tickets
    /// failed, so the store can apply exactly what reached the disk.
    static func commit(saveTickets: () throws -> Void, saveSettings: () throws -> Void) -> SaveOutcome {
        do { try saveTickets() } catch { return .ticketsFailed }
        do { try saveSettings() } catch { return .settingsFailed }
        return .saved
    }

    // MARK: - Summary

    struct Summary: Equatable {
        var addedActive = 0
        var addedArchived = 0
        var skipped = 0
        var droppedKeys: [String] = []
        var droppedPRs = 0
        var addedMappings = 0
        var droppedMappings = 0
        var restored: [String] = []

        static let maxListedKeys = 10
        static let maxKeyLength = 40

        var alertText: String {
            var lines = ["Added \(addedActive + addedArchived) tickets (\(addedActive) active, \(addedArchived) archived)."]
            if skipped > 0 { lines.append("Skipped \(skipped) already watched.") }
            if addedMappings > 0 { lines.append("Added \(addedMappings) Projects entries.") }
            if !restored.isEmpty { lines.append("Restored: \(restored.joined(separator: ", ")).") }
            if !droppedKeys.isEmpty {
                var listed = droppedKeys.prefix(Self.maxListedKeys).map(Self.shortened).joined(separator: ", ")
                if droppedKeys.count > Self.maxListedKeys { listed += ", and \(droppedKeys.count - Self.maxListedKeys) more" }
                lines.append("Dropped \(droppedKeys.count) invalid ticket keys: \(listed).")
            }
            if droppedPRs > 0 { lines.append("Dropped \(droppedPRs) invalid PR links.") }
            if droppedMappings > 0 { lines.append("Dropped \(droppedMappings) invalid Projects entries.") }
            return lines.joined(separator: "\n")
        }

        /// At most `maxKeyLength` characters, line breaks shown as ⏎.
        static func shortened(_ key: String) -> String {
            let flat = String(key.map { $0.isNewline ? "⏎" : $0 })
            return flat.count <= maxKeyLength ? flat : String(flat.prefix(maxKeyLength - 1)) + "…"
        }
    }

    // MARK: - Validation

    // Whole-string matching via `range(of:options:)`: NSRegularExpression's
    // `$` also matches before a trailing line break ("DEMO-1\n").
    static let ticketKeyPattern = #"^[A-Z][A-Z0-9_]+-[0-9]+$"#
    static let projectPrefixPattern = #"^[A-Z][A-Z0-9_]+$"#
    static let hostPattern = #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#
    static let orgPattern = #"^[A-Za-z0-9][A-Za-z0-9-]*$"#

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    /// `https://github.com/{owner}/{repo}/pull/{n}` and nothing else: the
    /// detail view force-unwraps the URL and opens it as a link.
    static func isGitHubPRURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              GitHubService.owner(fromPRURL: string) != nil else { return false }
        return URL(string: GitHubService.normalizePRURL(string)) != nil
    }

    // MARK: - JSON

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum BackupError: LocalizedError, Equatable {
    case notAFile, fileTooLarge, exportTooLarge, notABackup, newerVersion
    case demoMode, ticketsNotSaved, settingsNotSaved

    var errorDescription: String? {
        switch self {
        case .notAFile: return "Choose a regular backup file."
        case .fileTooLarge: return "This file is larger than 10 MB, which is more than any TicketRadar backup."
        case .exportTooLarge: return "This backup would be larger than 10 MB, which Import refuses, so it was not exported."
        case .notABackup: return "This file is not a TicketRadar backup."
        case .newerVersion: return "This backup was made by a newer version of TicketRadar."
        case .demoMode: return "Import is not available in demo mode."
        case .ticketsNotSaved: return "Nothing was imported: tickets could not be saved."
        case .settingsNotSaved: return "Tickets were imported, but settings could not be saved."
        }
    }
}

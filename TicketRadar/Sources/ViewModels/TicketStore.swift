import Foundation
import SwiftUI

@Observable
@MainActor
final class TicketStore {
    var tickets: [WatchedTicket] = []
    var settings: AppSettings = .default
    var selectedTicketID: UUID?
    private var pollTimer: Timer?

    /// Demo mode (DEBUG + `TR_DEMO=1`) seeds anonymized fixtures for screenshots.
    ///
    /// It is a full isolation switch, not just a data seed: persistence, polling
    /// and every shell-out are disabled. Gating only polling would leave an
    /// accidental Cmd+R free to overwrite the user's real `tickets.json` with
    /// demo content — or to replace the fixture with live fetch errors.
    private let isDemoMode: Bool

    init() {
        #if DEBUG
        self.isDemoMode = DemoData.isEnabled
        #else
        self.isDemoMode = false
        #endif

        if isDemoMode {
            #if DEBUG
            self.tickets = DemoData.tickets
            self.settings = DemoData.settings
            self.selectedTicketID = self.tickets.first?.id

            // No polling, no stale refresh, no disk access. The delay gives the
            // permission prompt time to clear before the banner appears.
            Task { @MainActor in
                NotificationService.requestPermission()
                try? await Task.sleep(for: .seconds(6))
                NotificationService.sendDemo()
            }
            #endif
            return
        }

        self.tickets = Self.migratePRURLs(PersistenceService.loadTickets())
        self.settings = PersistenceService.loadSettings()

        // Self-start: request notifications, start polling, refresh stale tickets
        Task { @MainActor [weak self] in
            guard let self else { return }
            NotificationService.requestPermission()
            self.startPolling()
            await self.refreshStaleTickets()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        guard !isDemoMode else { return }
        let interval = TimeInterval(settings.pollIntervalMinutes * 60)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollCycle()
            }
        }
    }

    func restartPolling() {
        startPolling()
    }

    private func pollCycle() async {
        for ticket in activeTickets {
            let oldTicket = ticket
            await refreshTicket(id: ticket.id)

            // Send notifications on state changes (only if we had previous data)
            if settings.notificationsEnabled,
               let updatedTicket = tickets.first(where: { $0.id == ticket.id }),
               !oldTicket.pullRequests.isEmpty {
                NotificationService.detectAndNotify(old: oldTicket, new: updatedTicket)
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Ticket Management

    func addTicket(input: String) {
        let ticketKey = Self.extractTicketKey(from: input)
        guard !ticketKey.isEmpty else { return }

        // Avoid duplicates
        guard !tickets.contains(where: { $0.ticketKey.uppercased() == ticketKey.uppercased() }) else {
            return
        }

        let ticket = WatchedTicket(ticketKey: ticketKey.uppercased())
        tickets.append(ticket)
        save()

        // Auto-refresh the newly added ticket
        Task {
            await refreshTicket(id: ticket.id)
        }
    }

    func removeTicket(id: UUID) {
        tickets.removeAll { $0.id == id }
        if selectedTicketID == id {
            selectedTicketID = tickets.first?.id
        }
        save()
    }

    func removeTickets(at offsets: IndexSet) {
        let idsToRemove = offsets.map { tickets[$0].id }
        tickets.remove(atOffsets: offsets)
        if let selected = selectedTicketID, idsToRemove.contains(selected) {
            selectedTicketID = tickets.first?.id
        }
        save()
    }

    func updateTicket(_ ticket: WatchedTicket) {
        guard let index = tickets.firstIndex(where: { $0.id == ticket.id }) else { return }
        tickets[index] = ticket
        save()
    }

    // MARK: - Archive

    func archiveTicket(id: UUID) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[index].isArchived = true
        save()
    }

    func unarchiveTicket(id: UUID) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[index].isArchived = false
        save()

        // Trigger a refresh to get fresh data
        Task {
            await refreshTicket(id: id)
        }
    }

    // MARK: - Computed (Active vs Archived)

    var activeTickets: [WatchedTicket] {
        tickets.filter { !$0.isArchived }
    }

    var archivedTickets: [WatchedTicket] {
        tickets.filter { $0.isArchived }
    }

    // MARK: - Refresh

    /// Refresh a single ticket: discover linked PRs, then fetch each from GitHub.
    ///
    /// PRs are discovered from two independent sources and merged:
    ///   1. Jira `inlineCard` smart-links in the ticket description (authoritative
    ///      for PRs whose titles don't follow the ticket-key convention).
    ///   2. `gh search prs --match title` across the configured GitHub org (finds
    ///      PRs that exist but haven't been linked in Jira yet).
    ///
    /// The search is best-effort: if it fails, the PRs it found last time are
    /// reused and the ticket is marked `Partial`, rather than failing the whole
    /// refresh or silently dropping search-only PRs.
    func refreshTicket(id: UUID) async {
        guard !isDemoMode else { return }
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }

        tickets[index].status = .loading
        let ticketKey = tickets[index].ticketKey
        let previousSearchURLs = tickets[index].searchPRURLs ?? []
        let customPath = settings.customToolPath
        let configuredOwner = settings.githubOwner(forTicketKey: ticketKey)
        let jiraSite = settings.jiraSite(forTicketKey: ticketKey)

        do {
            // 1. Fetch ticket info from Jira
            let ticketInfo = try await JiraService.fetchTicket(key: ticketKey, site: jiraSite, customPath: customPath)

            // Re-check index after async gap (user may have removed ticket)
            guard let idx1 = tickets.firstIndex(where: { $0.id == id }) else { return }
            tickets[idx1].title = ticketInfo.title
            tickets[idx1].jiraLoginSite = nil

            // 2. Discover PRs from both sources and merge
            let discovery = await discoverPRURLs(
                ticketKey: ticketKey,
                jiraURLs: ticketInfo.prURLs,
                configuredOwner: configuredOwner,
                previousSearchURLs: previousSearchURLs,
                customPath: customPath
            )
            let prURLs = discovery.urls

            // 3. Fetch all PRs in parallel from GitHub
            let results = prURLs.isEmpty
                ? []
                : await GitHubService.fetchPRs(urls: prURLs, customPath: customPath)

            var prs: [PullRequest] = []
            var errors: [String] = []
            if let searchError = discovery.searchError {
                errors.append("PR search failed: \(searchError)")
            }
            for result in results {
                switch result {
                case .success(let pr):
                    prs.append(pr)
                case .failure(let error):
                    errors.append(error.localizedDescription)
                }
            }

            // Re-check index again after second async gap
            guard let idx2 = tickets.firstIndex(where: { $0.id == id }) else { return }
            tickets[idx2].pullRequests = prs
            tickets[idx2].lastRefreshed = Date()
            if discovery.searchError == nil, discovery.searched {
                tickets[idx2].searchPRURLs = discovery.searchURLs
            }
            tickets[idx2].ssoBlockedOrg = discovery.ssoBlockedOrg

            // Track all successfully fetched PR URLs (set only grows)
            for pr in prs {
                tickets[idx2].knownPRURLs.insert(pr.url)
            }

            if errors.isEmpty {
                tickets[idx2].status = .ready
            } else {
                tickets[idx2].status = .error("Partial: \(errors.joined(separator: "; "))")
            }

            save()
        } catch {
            // Re-check index
            guard let currentIndex = tickets.firstIndex(where: { $0.id == id }) else { return }
            tickets[currentIndex].status = .error(error.localizedDescription)
            tickets[currentIndex].jiraLoginSite = (error as? ShellError)?.kind == .unauthorized ? (jiraSite ?? "") : nil
            save()
        }
    }

    private struct Discovery {
        var urls: [String]
        /// Search results to persist; only meaningful when `searched` and no error.
        var searchURLs: [String]
        var searched: Bool
        var searchError: String?
        var ssoBlockedOrg: String?
    }

    /// Merge PR URLs from Jira smart-links and a GitHub title search.
    ///
    /// Deduplicated by `GitHubService.prKey` (case-insensitive, canonical), so
    /// `.../pull/12/files`, `.../pull/12#x` and `.../Pull/12` collapse to one PR.
    /// Jira-sourced URLs come first and win, preserving the author's order and
    /// spelling.
    private func discoverPRURLs(
        ticketKey: String,
        jiraURLs: [String],
        configuredOwner: String?,
        previousSearchURLs: [String],
        customPath: String?
    ) async -> Discovery {
        let jiraNormalized = jiraURLs.map(GitHubService.normalizePRURL)

        // Fall back to the owner of the first linked PR when none is configured.
        let owner = configuredOwner ?? jiraNormalized.lazy.compactMap(GitHubService.owner(fromPRURL:)).first

        var discovery = Discovery(urls: [], searchURLs: [], searched: false)
        var searchURLs: [String] = []
        if let owner {
            discovery.searched = true
            do {
                searchURLs = try await GitHubService.searchPRs(
                    ticketKey: ticketKey,
                    owner: owner,
                    customPath: customPath
                )
                discovery.searchURLs = searchURLs
            } catch {
                // Keep last cycle's search-only PRs instead of dropping them.
                searchURLs = previousSearchURLs
                let message = error.localizedDescription
                discovery.searchError = message
                if message.localizedCaseInsensitiveContains("saml") {
                    discovery.ssoBlockedOrg = owner
                }
            }
        }

        var seen = Set<String>()
        discovery.urls = (jiraNormalized + searchURLs).filter { seen.insert(GitHubService.prKey($0)).inserted }
        return discovery
    }

    /// Bring PR URLs saved by earlier versions into canonical form.
    ///
    /// Runs after a successful decode, never inside a decoder: a decode failure
    /// makes `PersistenceService.loadTickets` return `[]`, and the next save
    /// would then wipe tickets.json.
    static func migratePRURLs(_ tickets: [WatchedTicket]) -> [WatchedTicket] {
        tickets.map { ticket in
            var t = ticket
            for i in t.pullRequests.indices {
                t.pullRequests[i].url = GitHubService.normalizePRURL(t.pullRequests[i].url)
            }
            t.knownPRURLs = Set(t.knownPRURLs.map(GitHubService.normalizePRURL))
            t.searchPRURLs = t.searchPRURLs?.map(GitHubService.normalizePRURL)
            return t
        }
    }

    /// Refresh all active (non-archived) tickets sequentially
    func refreshAll() async {
        guard !isDemoMode else { return }
        for ticket in activeTickets {
            await refreshTicket(id: ticket.id)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Refresh tickets that are stuck in idle or error state (excludes archived)
    func refreshStaleTickets() async {
        guard !isDemoMode else { return }
        let staleTickets = tickets.filter { ticket in
            guard !ticket.isArchived else { return false }
            switch ticket.status {
            case .idle, .error:
                return true
            default:
                return false
            }
        }

        for ticket in staleTickets {
            await refreshTicket(id: ticket.id)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        guard !isDemoMode else { return }
        PersistenceService.saveSettings(settings)
    }

    // MARK: - Computed Properties

    var actionableCount: Int {
        activeTickets.filter { $0.hasActionItems }.count
    }

    var selectedTicket: WatchedTicket? {
        guard let id = selectedTicketID else { return nil }
        return tickets.first { $0.id == id }
    }

    // MARK: - Private

    private func save() {
        // Demo mode must never touch the user's real watchlist. Every mutating
        // path funnels through here, so this is the single guard that matters.
        guard !isDemoMode else { return }
        PersistenceService.saveTickets(tickets)
    }

    /// Extract ticket key from a Jira URL or raw key input
    /// Supports: "PROJ-7328", "https://yourcompany.atlassian.net/browse/PROJ-7328"
    static func extractTicketKey(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract from URL path
        if let url = URL(string: trimmed),
           let host = url.host,
           host.contains("atlassian.net") {
            let pathComponents = url.pathComponents
            if let browseIndex = pathComponents.firstIndex(of: "browse"),
               browseIndex + 1 < pathComponents.count {
                return pathComponents[browseIndex + 1]
            }
            // fallback: last path component
            return url.lastPathComponent
        }

        // Try regex match for ticket key pattern
        let pattern = #"[A-Z][A-Z0-9]+-\d+"#
        if let range = trimmed.range(of: pattern, options: .regularExpression) {
            return String(trimmed[range])
        }

        return trimmed
    }
}

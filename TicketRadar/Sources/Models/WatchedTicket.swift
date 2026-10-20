import Foundation

enum TicketStatus: Codable, Equatable {
    case idle
    case loading
    case ready
    case error(String)
}

struct WatchedTicket: Identifiable, Codable, Equatable {
    let id: UUID
    var ticketKey: String
    var title: String?
    var pullRequests: [PullRequest]
    var lastRefreshed: Date?
    var status: TicketStatus
    /// Set of PR URLs that have ever been seen for this ticket (only grows, never shrinks).
    /// Used to prevent false "new PR linked" notifications from transient fetch failures.
    var knownPRURLs: Set<String>
    /// Whether this ticket is archived (excluded from polling, shown in a separate section).
    var isArchived: Bool
    /// PR URLs found by the last *successful* `gh search`. Reused when a search
    /// fails so search-only PRs don't vanish for a cycle. Optional so tickets
    /// saved by earlier versions still decode.
    var searchPRURLs: [String]?
    /// Org whose PR search was blocked by SAML SSO on the last refresh; drives
    /// the sign-in help in the ticket detail. Nil when search worked.
    var ssoBlockedOrg: String?
    /// Set when acli refused the Jira fetch as unauthorized: the site to sign
    /// in to again, or "" when the ticket has no configured site. Drives the
    /// sign-in help in the ticket detail. Nil when the fetch worked.
    var jiraLoginSite: String?

    init(
        id: UUID = UUID(),
        ticketKey: String,
        title: String? = nil,
        pullRequests: [PullRequest] = [],
        lastRefreshed: Date? = nil,
        status: TicketStatus = .idle,
        knownPRURLs: Set<String> = [],
        isArchived: Bool = false
    ) {
        self.id = id
        self.ticketKey = ticketKey
        self.title = title
        self.pullRequests = pullRequests
        self.lastRefreshed = lastRefreshed
        self.status = status
        self.knownPRURLs = knownPRURLs
        self.isArchived = isArchived
    }

    var openPRCount: Int {
        pullRequests.filter { $0.state == .open }.count
    }

    var mergedPRCount: Int {
        pullRequests.filter { $0.state == .merged }.count
    }

    var closedPRCount: Int {
        pullRequests.filter { $0.state == .closed }.count
    }

    var hasActionItems: Bool {
        pullRequests.contains { pr in
            pr.state == .open && (
                pr.reviewDecision == "CHANGES_REQUESTED" ||
                pr.unresolvedThreads > 0 ||
                pr.ciStatus == .failing
            )
        }
    }
}

#if DEBUG
import Foundation

/// Anonymized fixture data for capturing marketing screenshots.
///
/// Enabled only in DEBUG builds and only when `TR_DEMO=1` is present in the
/// environment, so normal behaviour is untouched:
///
/// ```bash
/// open --env TR_DEMO=1 -n --fresh \
///   "$(xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
///                 -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
///      | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/TicketRadar.app"
/// ```
///
/// `TR_DEMO=1 open ...` does **not** work — that sets the variable for `open`
/// itself, which does not forward its environment to the launched app.
///
/// When demo mode is active `TicketStore` never reads or writes
/// `~/Library/Application Support/TicketRadar/`, never polls, and never shells
/// out to `acli`/`gh`. See `TicketStore.isDemoMode`.
///
/// The fixture is built to exercise every visual state the UI can render:
/// all three PR states, all four review badges, all five CI badges, the
/// merge-status column, both actionable and non-actionable tickets, an
/// archived ticket, and all four `reviewWaitText` variants.
enum DemoData {

    /// Whether the app was launched in demo mode.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TR_DEMO"] == "1"
    }

    // MARK: - Settings

    /// A Jira base URL is set so the "Open in Jira" affordances are visible,
    /// and the poll interval is long because polling is disabled anyway.
    static var settings: AppSettings {
        AppSettings(
            pollIntervalMinutes: 30,
            notificationsEnabled: true,
            customToolPath: nil,
            jiraBaseURL: "https://acme-labs.atlassian.net",
            githubOwner: "acme-labs"
        )
    }

    // MARK: - Tickets

    static var tickets: [WatchedTicket] {
        [authTicket, redisTicket, flakyTestTicket, archivedTicket]
    }

    // MARK: - Relative dates

    private static func days(_ value: Double) -> Date {
        Date().addingTimeInterval(-value * 86_400)
    }

    private static func hours(_ value: Double) -> Date {
        Date().addingTimeInterval(-value * 3_600)
    }

    private static func url(_ repo: String, _ number: Int) -> String {
        "https://github.com/acme-labs/\(repo)/pull/\(number)"
    }

    // MARK: - Ticket 1: the hero ticket (actionable, full spread of states)

    /// Actionable: has a CHANGES_REQUESTED PR, unresolved threads and failing CI,
    /// so it drives the red row indicator and the menu bar badge.
    private static var authTicket: WatchedTicket {
        WatchedTicket(
            ticketKey: "DEMO-4821",
            title: "Add rate limiting to the auth service",
            pullRequests: [
                // OPEN · APPROVED · all-green CI · CLEAN · reviewed (frozen wait)
                PullRequest(
                    url: url("api-gateway", 142),
                    repository: "api-gateway",
                    number: 142,
                    title: "[DEMO-4821] Add rate limiting middleware",
                    state: .open,
                    reviewDecision: "APPROVED",
                    totalThreads: 3,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    comments: [
                        ReviewComment(
                            author: "alex.chen",
                            reviewState: "APPROVED",
                            body: "Looks good. The token bucket sizing matches what we agreed in the design doc, and the metrics wiring is a nice touch."
                        ),
                        ReviewComment(
                            author: "priya.nair",
                            reviewState: "COMMENT",
                            body: "Confirmed against the staging load test — steady at 4k req/s with no false throttling."
                        )
                    ],
                    createdAt: days(4),
                    firstReviewAt: days(3)
                ),
                // OPEN · CHANGES_REQUESTED · failing CI · BLOCKED · unresolved threads
                PullRequest(
                    url: url("web-app", 88),
                    repository: "web-app",
                    number: 88,
                    title: "[DEMO-4821] Surface rate limit errors in the UI",
                    state: .open,
                    reviewDecision: "CHANGES_REQUESTED",
                    totalThreads: 5,
                    unresolvedThreads: 2,
                    ciStatus: .failing,
                    mergeStatus: "BLOCKED",
                    comments: [
                        ReviewComment(
                            author: "sam.rivera",
                            reviewState: "CHANGES_REQUESTED",
                            body: "The retry banner swallows the Retry-After header. Please surface the actual wait time instead of the generic copy."
                        ),
                        ReviewComment(
                            author: "jordan.blake",
                            reviewState: "COMMENTED",
                            body: "Should we also handle the 429 case on the settings page, or is that out of scope for this ticket?"
                        )
                    ],
                    createdAt: days(6),
                    firstReviewAt: days(5)
                ),
                // OPEN · REVIEW_REQUIRED · mixed CI · UNSTABLE · still waiting (orange)
                PullRequest(
                    url: url("billing-service", 57),
                    repository: "billing-service",
                    number: 57,
                    title: "[DEMO-4821] Respect rate limit headers in the billing client",
                    state: .open,
                    reviewDecision: "REVIEW_REQUIRED",
                    totalThreads: 0,
                    unresolvedThreads: 0,
                    ciStatus: .mixed(passed: 3, total: 5),
                    mergeStatus: "UNSTABLE",
                    createdAt: days(2)
                ),
                // OPEN · no review decision yet · pending CI · BEHIND
                PullRequest(
                    url: url("notification-worker", 23),
                    repository: "notification-worker",
                    number: 23,
                    title: "[DEMO-4821] Back off when the auth service throttles",
                    state: .open,
                    reviewDecision: nil,
                    totalThreads: 1,
                    unresolvedThreads: 1,
                    ciStatus: .pending,
                    mergeStatus: "BEHIND",
                    createdAt: hours(20)
                ),
                // MERGED · threads and merge column collapse to "--"
                PullRequest(
                    url: url("shared-libs", 310),
                    repository: "shared-libs",
                    number: 310,
                    title: "[DEMO-4821] Extract the rate limiter into shared-libs",
                    state: .merged,
                    reviewDecision: "APPROVED",
                    totalThreads: 2,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    comments: [
                        ReviewComment(
                            author: "alex.chen",
                            reviewState: "APPROVED",
                            body: "Merged so the other PRs can pick it up."
                        )
                    ],
                    createdAt: days(12),
                    mergedAt: days(9),
                    firstReviewAt: days(11)
                ),
                // CLOSED · unknown CI · never reviewed, so the wait column reads "none"
                PullRequest(
                    url: url("legacy-adapter", 12),
                    repository: "legacy-adapter",
                    number: 12,
                    title: "[DEMO-4821] Spike: throttle the legacy adapter",
                    state: .closed,
                    reviewDecision: nil,
                    totalThreads: 0,
                    unresolvedThreads: 0,
                    ciStatus: .unknown,
                    mergeStatus: nil,
                    createdAt: days(20),
                    closedAt: days(18)
                )
            ],
            lastRefreshed: Date().addingTimeInterval(-120),
            status: .ready
        )
    }

    // MARK: - Ticket 2: finished work (merged only, not actionable)

    private static var redisTicket: WatchedTicket {
        WatchedTicket(
            ticketKey: "DEMO-4796",
            title: "Migrate the session store to Redis",
            pullRequests: [
                PullRequest(
                    url: url("api-gateway", 138),
                    repository: "api-gateway",
                    number: 138,
                    title: "[DEMO-4796] Swap the session backend for Redis",
                    state: .merged,
                    reviewDecision: "APPROVED",
                    totalThreads: 4,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    createdAt: days(15),
                    mergedAt: days(11),
                    firstReviewAt: days(14)
                ),
                PullRequest(
                    url: url("shared-libs", 298),
                    repository: "shared-libs",
                    number: 298,
                    title: "[DEMO-4796] Add a Redis session adapter",
                    state: .merged,
                    reviewDecision: "APPROVED",
                    totalThreads: 1,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    createdAt: days(17),
                    mergedAt: days(14),
                    firstReviewAt: days(16)
                ),
                // Timestamps unavailable — exercises the "--" age and wait variants.
                PullRequest(
                    url: url("web-app", 77),
                    repository: "web-app",
                    number: 77,
                    title: "[DEMO-4796] Drop the sticky-session workaround",
                    state: .merged,
                    reviewDecision: "APPROVED",
                    totalThreads: 0,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN"
                )
            ],
            lastRefreshed: Date().addingTimeInterval(-540),
            status: .ready
        )
    }

    // MARK: - Ticket 3: waiting on a reviewer, but not actionable

    private static var flakyTestTicket: WatchedTicket {
        WatchedTicket(
            ticketKey: "DEMO-5010",
            title: "Fix the flaky checkout integration test",
            pullRequests: [
                PullRequest(
                    url: url("web-app", 91),
                    repository: "web-app",
                    number: 91,
                    title: "[DEMO-5010] Stabilise the checkout integration test",
                    state: .open,
                    reviewDecision: "REVIEW_REQUIRED",
                    totalThreads: 0,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    createdAt: hours(30)
                )
            ],
            lastRefreshed: Date().addingTimeInterval(-900),
            status: .ready
        )
    }

    // MARK: - Ticket 4: archived

    private static var archivedTicket: WatchedTicket {
        WatchedTicket(
            ticketKey: "DEMO-4502",
            title: "Deprecate the v1 metrics endpoint",
            pullRequests: [
                PullRequest(
                    url: url("api-gateway", 121),
                    repository: "api-gateway",
                    number: 121,
                    title: "[DEMO-4502] Remove the v1 metrics endpoint",
                    state: .merged,
                    reviewDecision: "APPROVED",
                    totalThreads: 2,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    createdAt: days(40),
                    mergedAt: days(36),
                    firstReviewAt: days(39)
                ),
                PullRequest(
                    url: url("shared-libs", 274),
                    repository: "shared-libs",
                    number: 274,
                    title: "[DEMO-4502] Drop the v1 metrics serializer",
                    state: .merged,
                    reviewDecision: "APPROVED",
                    totalThreads: 0,
                    unresolvedThreads: 0,
                    ciStatus: .passing,
                    mergeStatus: "CLEAN",
                    createdAt: days(42),
                    mergedAt: days(38),
                    firstReviewAt: days(41)
                )
            ],
            lastRefreshed: days(36),
            status: .ready,
            isArchived: true
        )
    }
}
#endif

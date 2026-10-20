# TicketRadar — Implementation Plan

> macOS menu bar app that monitors Jira ticket PR status via `acli` + `gh`

## Summary

A native macOS menu bar app (Swift + SwiftUI) that lets you maintain a watchlist
of Jira tickets, automatically polls for PR status via existing CLI tools
(`acli` + `gh`), displays results in a full window, and sends macOS
notifications on state changes.

---

## Choices Made

| Decision             | Choice                                   |
|----------------------|------------------------------------------|
| Tech stack           | Swift + SwiftUI (native macOS)           |
| Auto-refresh         | Yes, periodic polling (configurable)     |
| Authentication       | Shell out to `acli` and `gh`             |
| UI depth             | Full window app (menu bar icon + window) |
| Notifications        | Yes, on PR state changes                 |
| Summary generation   | Programmatic + raw comments (no AI)      |
| App name             | TicketRadar                              |
| macOS target         | macOS 14+ (Sonoma)                       |

---

## Architecture Overview

```
+---------------------------------------------------+
|  TicketRadar.app (SwiftUI, macOS 14+)             |
+---------------------------------------------------+
|  Menu Bar Icon (NSStatusItem)                     |
|    +-- Click -> Opens main window                 |
+---------------------------------------------------+
|  Main Window                                      |
|    +-- Sidebar: Watched tickets list              |
|    +-- Detail: PR status table + action items     |
+---------------------------------------------------+
|  Services Layer                                   |
|    +-- ShellExecutor (Process wrapper)            |
|    +-- JiraService (acli -> ticket -> PR URLs)    |
|    +-- GitHubService (gh -> PR status/reviews)    |
|    +-- PollingManager (Timer-based refresh)       |
|    +-- NotificationService (UNUserNotification)   |
+---------------------------------------------------+
|  Persistence (JSON in ~/Library/App Support)      |
+---------------------------------------------------+
```

---

## Project Structure

As built (differs from the original sketch — see "Plan Deviations" below):

```
ticket-radar/
+-- project.yml                          # XcodeGen manifest — the build source of truth
+-- AGENTS.md                            # Build instructions for agents
+-- docs/
|   +-- implementation-plan.md           # This file
|   +-- plans/                           # Pending feature plans
+-- TicketRadar/
|   +-- Sources/
|   |   +-- TicketRadarApp.swift         # @main, MenuBarExtra + Window + Settings
|   |   +-- Models/
|   |   |   +-- WatchedTicket.swift      # Ticket key, title, PRs, archive flag
|   |   |   +-- PullRequest.swift        # PR URL, state, review, CI, threads, times
|   |   |   +-- AppSettings.swift        # Poll interval, notifications, Jira base URL
|   |   +-- Services/
|   |   |   +-- ShellExecutor.swift      # async Process wrapper + PATH resolution
|   |   |   +-- JiraService.swift        # acli workitem view -> extract PR URLs
|   |   |   +-- GitHubService.swift      # gh pr view + gh api graphql
|   |   |   +-- NotificationService.swift# UNUserNotificationCenter + change diffing
|   |   |   +-- PersistenceService.swift # JSON encode/decode watchlist + settings
|   |   +-- ViewModels/
|   |   |   +-- TicketStore.swift        # @MainActor @Observable — watchlist,
|   |   |                                #   refresh, polling, archive
|   |   +-- Views/
|   |       +-- MainWindowView.swift     # NavigationSplitView (sidebar+detail)
|   |       +-- MenuBarView.swift        # Menu bar popover
|   |       +-- TicketListView.swift     # Sidebar, active + archived sections
|   |       +-- TicketRowView.swift      # Single ticket row with badge
|   |       +-- TicketDetailView.swift   # PR status table + review comments
|   |       +-- AddTicketSheet.swift     # TextField for ticket key/URL
|   |       +-- SettingsView.swift       # Poll interval, notifications, paths
|   +-- Resources/
|       +-- Assets.xcassets              # Menu bar icon, app icon
|       +-- Info.plist
+-- screenshots/                         # README assets, from demo data (see docs/plans/demo-data.md)
```

There is no `TicketRadarTests/` target yet, and no `Package.swift` — SwiftPM is
deliberately unsupported (see `AGENTS.md`).

---

## Data Models

### WatchedTicket

```swift
struct WatchedTicket: Identifiable, Codable {
    let id: UUID
    var ticketKey: String          // e.g. "DEMO-4821"
    var title: String?             // fetched from Jira
    var pullRequests: [PullRequest]
    var lastRefreshed: Date?
    var status: TicketStatus       // .loading, .ready, .error(String)
}
```

### PullRequest

```swift
struct PullRequest: Identifiable, Codable {
    let id: UUID
    var url: String
    var repository: String
    var number: Int
    var title: String
    var state: PRState             // .open, .merged, .closed
    var reviewDecision: String?    // APPROVED, CHANGES_REQUESTED, etc.
    var totalThreads: Int
    var unresolvedThreads: Int
    var ciStatus: CIStatus
    var mergeStatus: String?
    var actionItems: [ActionItem]
}
```

### ActionItem

```swift
struct ActionItem: Identifiable, Codable {
    let id: UUID
    var author: String
    var reviewState: String        // CHANGES_REQUESTED, COMMENTED, etc.
    var body: String               // raw comment text
}
```

---

## Summary Generation Strategy

| Component            | Method       | Details                                                                 |
|----------------------|--------------|-------------------------------------------------------------------------|
| Status table         | Programmatic | Parse `gh` JSON -> structured `PullRequest` model -> SwiftUI `Table`    |
| Ticket-level summary | Programmatic | Count merged/open/closed, flag failing CI, blocked merges, unresolved   |
| Action items         | Raw display  | Show review comments grouped by author + review state. Expandable text. |
| Menu bar badge       | Programmatic | Red dot / count: open PRs with CHANGES_REQUESTED, failing CI, etc.     |

---

## Detail View Layout (per ticket)

```
+-------------------------------------------------------+
| DEMO-4821 -- "Add rate limiting to the auth service"  |
| Last refreshed: 2 min ago              [Refresh]      |
+-------------------------------------------------------+
| Summary: 2 open, 1 merged | 1 needs review | 1 CI !  |
+-------------------------------------------------------+
| +---------------------------------------------------+ |
| | PR Table (repo, #, state, review, CI, merge)      | |
| +---------------------------------------------------+ |
+-------------------------------------------------------+
| Reviews & Comments                                    |
| > api-gateway #142 (OPEN)                            |
|   @reviewer1 (CHANGES_REQUESTED):                    |
|   "Please update the error handling in..."           |
|   @reviewer2 (COMMENTED):                            |
|   "Should we also consider the edge case..."         |
| > web-app #88 (OPEN)                                 |
|   No review comments.                                |
+-------------------------------------------------------+
```

---

## Implementation Phases

### Phase 1 — Skeleton (menu bar + window + persistence)

1. Create Xcode project (macOS App, SwiftUI lifecycle, menu bar extra)
2. Implement `NSStatusItem` with a radar icon (SF Symbol: `antenna.radiowaves.left.and.right`)
3. Create `NavigationSplitView` with sidebar (ticket list) and detail pane
4. Implement `PersistenceService` — save/load `[WatchedTicket]` as JSON in
   `~/Library/Application Support/TicketRadar/`
5. Implement `AddTicketSheet` — accepts ticket key (e.g. `DEMO-4821`) or full Jira URL
6. Wire up add/remove from watchlist

### Phase 2 — Shell integration (Jira + GitHub)

7. Implement `ShellExecutor` — async wrapper around `Process` that captures
   stdout/stderr, handles PATH (inherit user's shell environment so `acli` and
   `gh` are found)
8. Implement `JiraService`:
   - Runs `acli jira workitem view <KEY> --json`
   - Parses JSON to extract ticket title + PR URLs from description `inlineCard` nodes
9. Implement `GitHubService`:
   - Runs `gh pr view <url> --json title,state,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup`
   - Runs `gh api graphql` for review threads, review bodies, comments
   - Parses JSON responses into `PullRequest` model
10. Wire services into `TicketDetailViewModel` — on-demand refresh for a single ticket

### Phase 3 — Polling + notifications

11. Implement `PollingManager`:
    - Configurable interval (default: 5 minutes)
    - Iterates over watched tickets, refreshes each
    - Compares previous state to new state, emits change events
12. Implement `NotificationService`:
    - Request notification permission on first launch
    - Send notifications for: PR approved, PR merged, CI failed, new review comments
    - Each notification includes ticket key + repo + what changed
    - Example: "DEMO-4821: PR #142 in api-gateway was approved"
13. Add badge to menu bar icon when there are actionable changes (red dot / count)

### Phase 4 — Polish

14. Settings view: poll interval slider, notification toggles, PATH override
15. Error handling: show inline errors per ticket (e.g. `acli` not found, auth expired)
16. Menu bar context menu: quick actions (refresh all, open Jira ticket in browser)
17. Keyboard shortcuts: Cmd+N (add ticket), Cmd+R (refresh), Delete (remove)
18. App icon and menu bar icon design

---

## Technical Considerations

| Concern                        | Approach                                                                 |
|--------------------------------|--------------------------------------------------------------------------|
| PATH for CLI tools             | Use `/usr/bin/env` + read `~/.zprofile`. Allow override in settings.     |
| Concurrent fetches             | Swift Concurrency (`async let` / `TaskGroup`) for parallel PR checks     |
| Rate limiting                  | Space out polling per ticket with small delays between GitHub API calls   |
| macOS version                  | Target macOS 14+ for `@Observable` macro                                 |
| Sandbox                        | Non-sandboxed (needs shell access to `acli`/`gh`)                        |
| State change detection         | Hash relevant fields of `PullRequest` before/after; notify only on diff  |
| Large comment bodies           | Truncate to ~200 chars with "Show more" toggle                           |

---

## Risks and Mitigations

1. **`acli`/`gh` not in PATH from GUI app context** — macOS GUI apps don't
   inherit terminal PATH. Mitigation: read `~/.zprofile` or let user configure
   tool paths in settings.

2. **JSON output format changes in `acli`** — Mitigation: defensive parsing with
   fallbacks, log raw output on parse failure.

3. **Long-running refreshes blocking UI** — Mitigation: all shell calls are
   `async`, UI shows loading spinners per-ticket.

4. **GitHub API rate limits** — Mitigation: respect 5000 req/hour limit; with
   5-min polling and ~3 API calls per PR, supports ~50 watched PRs comfortably.

---

## Out of Scope (v1)

- Direct Jira/GitHub API calls (no token management in-app)
- ~~Multiple Jira instances~~ — *now supported: per-prefix Jira sites via
  `acli jira auth switch` (`Services/JiraService.swift`, `JiraSiteGate`)*
- Filtering/sorting tickets by status
- Auto-launch at login (easy to add later via `SMAppService`)
- AI-based summarization of comments
- Export/share functionality — *now planned, see `docs/plans/import-export.md`*

---

## Plan Deviations (Acceptable)

- Plan defined `TicketDetailViewModel` as a separate file; implementation puts refresh logic directly in `TicketStore`. Simpler architecture, fewer files.
- Plan defined a standalone `PollingManager` service; implementation keeps the timer inside `TicketStore` (`startPolling` / `restartPolling`). Same reasoning.
- Plan defined `ActionItem` model; implementation uses `ReviewComment` instead. More accurate naming since we chose raw comments over AI summarization.

## Shipped Beyond the Original Plan

- **PR timing metrics** — `createdAt` / `mergedAt` / `firstReviewAt` with derived
  PR age and time-to-first-review columns (`Models/PullRequest.swift:55-147`).
- **Archive** — tickets can be archived and are excluded from polling and
  refresh (`Models/WatchedTicket.swift:21`, `TicketStore.swift:103-127`).
- **Configurable Jira base URL** — enables "Open in Jira" links
  (`Models/AppSettings.swift:9`).
- **Hybrid PR discovery** — PRs are found both from Jira `inlineCard` links and
  from a GitHub title search across the configured org, merged and deduplicated
  on normalized URLs (`Services/GitHubService.swift`, `ViewModels/TicketStore.swift`).
- **Multiple Jira sites and GitHub orgs** — a *Projects* setting maps
  each ticket prefix to a Jira site and a GitHub org; Jira fetches are
  serialized and switch the active `acli` site when needed
  (`Models/AppSettings.swift`, `Services/JiraService.swift`).
- **Failure help** — GitHub SAML SSO blocks and expired `acli`
  sign-ins are reported as such, with copyable fix commands
  (`Views/SettingsView.swift`, `Views/TicketDetailView.swift`).
- **DEBUG self-check** — `TR_SELFCHECK=1` runs discovery, settings and
  site-gate checks and exits 0/1 (`DebugSelfCheck.swift`).
- **Demo mode** — `TR_DEMO=1` seeds anonymized fixtures for screenshots
  (`DemoData.swift`).
- **Dock reopen** — clicking the Dock icon reopens the closed main
  window (`TicketRadarApp.swift`).
- **Banners while frontmost** — `AppDelegate` is the notification
  delegate and asks for banners even while TicketRadar is in front
  (`TicketRadarApp.swift`). Settings restarts polling only when the refresh
  interval changes (`Views/SettingsView.swift`).
- **Unique notification identifiers** — a repeated event on the same
  PR no longer replaces the earlier notification silently; each one shows a
  banner and gets its own entry (`Services/NotificationService.swift`).

---

## Pending Work

Tracked separately under `docs/plans/` — see `docs/plans/README.md` for the
recommended implementation order.


# PR Report — Backlog Item

> **Status: Backlog.** Captured 2026-10-19, not planned in detail. Turn it
> into a plan (and challenge that plan) before implementing.

## Goal

Compose a report on the PRs of one or more tickets, showing how long each PR
took and where the time went: total time open, waiting for review, waiting
on the author, blocked, and time to merge.

## What the app already has

Per PR, from the last refresh (`Models/PullRequest.swift`):

| Field | Source | Gives |
|-------|--------|-------|
| `createdAt`, `mergedAt`, `closedAt` | `gh pr view --json` | Lead time (`openDuration`) |
| `firstReviewAt` | GraphQL reviews + comments, first non-author non-bot | Time to first review (`reviewWaitText`) |
| `reviewDecision`, `ciStatus`, `mergeStatus`, `unresolvedThreads` | `gh pr view` / GraphQL | **Current state only**, no history |

So today the report could show lead time and time to first review. "Waiting"
and "blocked" are *periods*, and the app only stores snapshots.

## Getting history

1. **GitHub timeline (evaluate first).** One more GraphQL query per PR,
   through the existing `gh api graphql` path (`fetchReviewData` pattern):
   `timelineItems(itemTypes: [READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT,
   REVIEW_REQUESTED_EVENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT,
   MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT])`. Gives exact history, even
   for PRs merged before the ticket was watched. CI history is separate
   (`commits { commit { checkSuites … } }`) and heavier.
2. **Record transitions while polling.** Cheap, but covers only the time the
   app was running and the ticket was watched. Not enough on its own.

## Candidate metrics (definitions to agree)

| Metric | Candidate definition |
|--------|----------------------|
| Lead time | Opened → merged / closed |
| Draft time | Opened (as draft) → ready for review, plus later draft periods |
| Waiting for review | Ready for review / review requested → next review by someone other than the author |
| Waiting on author | Changes requested → author's next commit |
| Blocked | CI failing on the head commit, or merge state `BLOCKED` / `BEHIND` (needs CI history) |
| Review rounds | Number of changes-requested → re-review cycles |

## Decisions before planning

- **Scope:** one ticket, selected tickets, or all (archived too)? Date range?
- **Output:** Markdown to the clipboard, a `.md` file, CSV for a
  spreadsheet, or an in-app view?
- **Time:** calendar time, or working hours (weekends excluded)?
- **Blocked in v1:** include CI-based blocked time (more queries), or start
  with review- and merge-state-based periods only?
- **Bots:** exclude bot reviews and comments, as `firstReviewAt` already does?

## Likely touch points

- `Services/GitHubService.swift` — timeline query.
- `Models/PullRequest.swift` — timeline events or computed periods, as
  optional fields so existing `tickets.json` files still decode.
- New `Services/ReportService.swift` — pure functions: events → periods →
  report text. Add cases to `DebugSelfCheck.swift`.
- `TicketRadarApp.swift` / `Views/TicketDetailView.swift` — a "Copy PR
  report" command or button. Overlaps with the File menu commands planned in
  `import-export.md`.
- `DemoData.swift` — fixtures need timelines for a screenshot.

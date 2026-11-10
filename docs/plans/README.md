# Plans

Feature plans and their status. Pending plans touch overlapping files, so
implement them one at a time, in the order below.

| Order | Plan | Status | Scope |
|-------|------|--------|-------|
| ~~—~~ | [`demo-data.md`](demo-data.md) | **Implemented** (screenshots captured 2026-10-19) | `TR_DEMO=1` seed with anonymized fixtures so README screenshots can be captured without exposing real Jira/GitHub data. |
| ~~—~~ | [`import-export.md`](import-export.md) | **Implemented** (2026-11) | File → Export / Import Backup…: every ticket and the settings in one `.json` file; import adds what is missing and never overwrites tickets or *Projects* entries. |
| 1 | [`pr-report.md`](pr-report.md) | **Backlog** — decisions needed before planning | Report on a ticket's PRs and where their time went: lead time, waiting for review, waiting on the author, blocked. Needs PR history (GitHub timeline). |

### Ideas, not planned yet

- **Jira ticket status** — show each ticket's Jira status (e.g. To Do, In
  Progress, Done). `acli jira workitem view --json` already returns
  `fields.status` by default; `JiraService` reads only `summary` and
  `description` today.
- **Sorting the ticket list** — manual (drag to reorder), by time or by name.
  Today tickets appear in the order they were added. Open: which time (added,
  last refreshed, last PR activity). Related: "filtering/sorting tickets by
  status" is listed as out of scope in `implementation-plan.md`.

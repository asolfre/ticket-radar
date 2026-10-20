# Plans

Feature plans and their status. Pending plans touch overlapping files, so
implement them one at a time, in the order below.

| Order | Plan | Status | Scope |
|-------|------|--------|-------|
| ~~—~~ | [`demo-data.md`](demo-data.md) | **Implemented** (screenshots captured 2026-10-19) | `TR_DEMO=1` seed with anonymized fixtures so README screenshots can be captured without exposing real Jira/GitHub data. |
| 1 | [`import-export.md`](import-export.md) | Not implemented — **predates multi-site Jira support, review before implementing** | `.ticketradar` export/import of the watchlist, incl. Finder file association. |
| 2 | [`pr-report.md`](pr-report.md) | **Backlog** — decisions needed before planning | Report on a ticket's PRs and where their time went: lead time, waiting for review, waiting on the author, blocked. Needs PR history (GitHub timeline). |

## Why the order matters

Both pending plans add File menu commands in `TicketRadarApp.swift`, so do
`import-export` first, then `pr-report`:

| File | import-export | pr-report |
|------|---------------|-----------|
| `ViewModels/TicketStore.swift` | `export/importTickets` + `init` | — |
| `Models/WatchedTicket.swift` | export format | — |
| `Models/PullRequest.swift` | — | timeline events (optional fields) |
| `Services/GitHubService.swift` | — | timeline query |
| `TicketRadarApp.swift` | File menu, open-file handling | "Copy PR report" command |
| `project.yml` (`info.properties`) | UTI + document types | — |

> ⚠️ **`import-export` predates multi-site Jira support.** The export carries ticket keys only,
> not the *Projects* mapping (`githubOwners`, `jiraSites`). Imported tickets
> from a prefix the receiver hasn't mapped are fetched from the receiver's
> default Jira site and fail. Decide whether to export the mapping too, or
> document that the receiver sets up *Projects* first.

> ⚠️ **`Info.plist` is generated.** `project.yml` has an `info:` block whose
> `path` is `TicketRadar/Resources/Info.plist`, so `xcodegen generate` rewrites
> that file. The `import-export` plan's instruction to hand-edit `Info.plist`
> would be silently reverted — document types must be declared in
> `project.yml` under `info.properties`.

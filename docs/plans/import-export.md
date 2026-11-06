# Backup: export and import — plan

**Base:** `origin/main` @ `73c92fd` (2026-10-22) · **Branch:** `feature/import-export` ·
**Status:** planned 2026-11-06, challenged three times (R1–R3) and amended

## 0. Status
- [ ] 1. Backup format, read, merge and save logic (`Models/Backup.swift`)
- [ ] 2. Store wrappers and save errors (`TicketStore`, `PersistenceService`)
- [ ] 3. File menu commands, panels and alerts (`TicketRadarApp.swift`)
- [ ] 4. Settings window reloads when the store's settings change
- [ ] 5. Self-check cases
- [ ] 6. Docs

Next: build · Open: none

## 1. Goal
Back up the whole setup to one file and restore it on the same or another Mac,
from the File menu. Copying `tickets.json` and `settings.json` already works;
this makes it one menu command each way, merging instead of overwriting.

Acceptance criteria:
1. **File → Export Backup…** (⇧⌘E) writes one `.json` file with every ticket,
   active and archived (archived ones with their PR snapshot), and the settings
   except `customToolPath`. An export larger than 10,000,000 bytes, which
   Import would refuse, is refused with an explanation.
2. **File → Import Backup…** (⇧⌘I) adds every ticket whose key is not already
   watched, once even if the file repeats it, each with a new id. No imported
   ticket keeps its search cache or sign-in banners. Archived tickets keep their
   archived state, status and PR snapshot. Imported active tickets also arrive
   without their PR snapshot (the list of PRs already seen is kept) and are
   refreshed. Tickets already watched keep this Mac's data.
3. The *Projects* mapping is merged per prefix, prefixes in sorted order: a
   Jira site or GitHub org this Mac has not set for a prefix is added; existing
   entries are never overwritten. A prefix must look like a Jira project key
   (`^[A-Z][A-Z0-9_]+$` after trimming and uppercasing). A value is trimmed and
   must not be empty; a site is stored as its host and contains a dot, an org
   does not; neither contains `,`, `=` or a line break. An entry is accepted
   only if it comes back unchanged from the Settings text format. Other entries
   are dropped.
4. Poll interval (only 1–30 minutes) and notifications are restored from the
   backup; a changed interval takes effect at once. The Jira base URL and the
   default GitHub org are restored only when this Mac has none. An empty value
   in the backup never clears one set here. `customToolPath` is neither
   exported nor imported.
5. After an import, the existing stale-ticket loop refreshes the imported
   active tickets one at a time. A launch refresh or a second import running at
   the same time can refresh a ticket twice; that is harmless.
6. An alert reports added tickets (active, archived), skipped tickets (already
   watched), dropped entries (invalid keys, PR URLs, mapping entries; up to 10
   keys listed, each shortened to 40 characters with line breaks shown as ⏎,
   then "and N more"), added mapping entries and restored settings. An
   invalid, newer-version or too-large file shows an error and changes nothing.
   If saving fails, an error alert says which part was not saved instead of
   the summary.
7. Works with the main window closed: the commands are in the File menu while
   TicketRadar is the active app, and the panels and alert open in front.
   Import is refused in demo mode.
8. A hand-edited file cannot crash the app, run away with work, freeze it or
   inject options, Settings lines or Terminal commands: only regular files
   (after resolving links) are read, and at most 10,000,000 bytes; invalid
   keys, PR URLs, mapping entries and poll intervals are dropped or ignored;
   cached searches and sign-in banners are not imported (AC2–AC4, §2).

## 2. Findings (source inspected 2026-11-06 at `73c92fd`; R1–R3 probes executed)
- No File menu commands exist. Scenes: `MenuBarExtra`, `Window("main")`,
  `Settings`; `AppDelegate` handles Dock reopen and notifications.
- Archived tickets are never refreshed (`refreshAll` / `refreshStaleTickets`
  skip them; `unarchiveTicket` triggers a refresh). A backup without their
  `pullRequests` would restore empty archived tickets.
- `refreshStaleTickets()` refreshes non-archived tickets in `.idle` or `.error`
  one at a time, 1 s apart. Each caller runs its own loop.
- `pollCycle` notifies whenever the old copy of a ticket has PRs
  (`NotificationService.detectAndNotify` returns early only when it has none):
  a days-old snapshot on an imported active ticket would produce stale
  "merged" and "approved" notifications.
- When GitHub search fails, a refresh reuses the ticket's `searchPRURLs`
  (`TicketStore.swift:181`, `:290-304`), and `GitHubService.fetchPRs` starts
  one task per URL with two `gh` calls each, with no limit. This includes the
  refresh that unarchiving starts. R3: 200,000 distinct PR URLs fit in one
  archived ticket in a file under 10 MB.
- The sign-in banners (`ssoBlockedOrg`, `jiraLoginSite`) are saved with the
  ticket and shown whether it is archived or not (`TicketDetailView.swift:106-112`);
  the Jira one puts the site into a command with a Copy button
  (`SettingsView.swift:144`).
- `startPolling` computes `pollIntervalMinutes * 60` with no range check:
  `Int.max` traps (crash, then again at every launch, since it is saved); `0`
  fires the timer about 1,100 times in 0.2 s. The slider allows only 1–30.
- `ShellExecutor` runs `/usr/bin/env <tool>` with the PATH from
  `customToolPath`: importing it would let a file choose which `acli`/`gh` runs.
- Ticket keys reach `acli` as an argument (no shell). A key such as `--web`
  would be read as an option. The app stores keys with underscores today
  (from a `/browse/MY_PROJ-12` link).
- `NSRegularExpression.firstMatch` with `^…$` accepts a trailing `\n`, `\r`
  or U+2028 (`"DEMO-1\n"`); `String.range(of:options: .regularExpression)`
  on the whole string and `Regex.wholeMatch` reject it (R3, executed).
- `TicketDetailView.swift:200` force-unwraps `URL(string: pr.url)`. The
  existing checks do not protect it: `JiraService.isGitHubPRURL` only matches
  substrings, `parsePRURL` checks no host, and `normalizePRURL` returns input it
  cannot parse unchanged. `https://[github.com/a/pull/1` passes all three and
  crashes the view; `file:///…?github.com/pull/1` becomes a link to a local app.
- `SettingsView` loads from the store only on appear and saves its whole draft
  on every change; a reload on every store change would also fire after its own
  saves and rewrite the text being typed (`api = a` becomes `API = a`).
- `formatProjectMap` writes each prefix and value into the Settings text as
  is, and `parseProjectMap` reads it back line by line, trimming values and
  keeping a site's host. A prefix holding `=` and a line break
  (`"DATA = acme-health\nAPI"`) overwrote this Mac's `DATA` org after one
  Settings save (R2, executed). An empty org `""` passes a dot rule but hides
  the default org, because the fallback applies only to `nil`
  (`AppSettings.swift:56-58`); a site with a scheme, a padded value and a
  lowercase prefix all change on the next Settings save (R3, executed).
- With no mapping for a prefix, the Jira site falls back to the base URL's host
  and the GitHub search to the default org: changing either changes how
  existing unmapped tickets are fetched.
- Tickets are looked up, removed and listed by `id`: ids from a file cannot be
  trusted.
- `URLResourceValues.fileSize` describes the URL itself: a symlink reports its
  own size (about 100 bytes) while `Data(contentsOf:)` reads its target; a FIFO
  or device has no size, and opening a FIFO blocks (R3, executed).
- `PersistenceService.saveTickets` / `saveSettings` discard encode and write
  errors (`try?`): a caller cannot tell that a save failed. An `.atomic` write
  fails for a read-only folder or a locked file (`chflags uchg`), not for a
  read-only file in a writable folder (`chmod 444`) (R3, executed).
- `TicketStore.migratePRURLs` is main-actor-isolated (`TicketStore` is
  `@MainActor`); a pure `Backup` function can call it only once it is
  `nonisolated` (R1 build: fails as is, builds with the change).
- Size: the user's `tickets.json` was 306 KB for 44 tickets on 2026-11-06,
  about 7 KB a ticket, so 10 MB holds about 1,400 tickets.
- ISO 8601 encoding drops fractions of a second, as `tickets.json` does today.
- `TicketStore.init` reads the real data folder, so the self-check must test
  pure functions, never a new `TicketStore`.

## 3. Risks
| # | Risk | Mitigation |
|---|------|------------|
| R1 | Settings open during import writes the old mapping back | Item 4: reload only when the store differs from the draft |
| R2 | PATH hijack through `customToolPath` | Neither exported nor imported (AC4), T4 |
| R3 | Crash, option injection or Settings-line injection from a hand-edited file | Validate keys, PR URLs and mapping entries with whole-string matching and a format → parse check (AC3, AC8), T3, T5, T6 |
| R4 | Format tied to `WatchedTicket` / `AppSettings` Codable | Optional fields decode as in `tickets.json`. Older apps reject a newer `version`; bump it for any change older apps cannot read (e.g. a new enum case). T7 |
| R5 | Self-check touching real data | Logic in pure `Backup` functions (item 1) |
| R6 | `pr-report` also adds File menu commands | This plan first, per `docs/plans/README.md` |
| R7 | PR #2 edits `README.md` and `docs/plans/README.md` | Write the docs after PR #2 merges, on the rebased branch |
| R8 | Poll interval from the file | Only 1–30 accepted (AC4), T9 |
| R9 | Stale notification burst | Imported active tickets drop their PR snapshot (AC2), T8 |
| R10 | Overlapping refresh loops | Accepted: a double refresh is harmless (AC5) |
| R11 | Hands-on test damaging real data | Quit every running copy, copy the data folder first, restore it afterwards (§7) |
| R12 | Unbounded work or a frozen app from a large or special file | Regular files only, at most 10 MB read (T10); search cache dropped on every imported ticket (T8) |
| R13 | Import shown as successful when a save failed | Saves throw; the alert names the part not saved (T11, §7.6) |
| R14 | A command to paste into Terminal coming from the file | Sign-in banners dropped on every imported ticket (T8) |
| R15 | A backup Import would refuse | Export refuses over 10 MB (T13) |

## 4. Scope
- **In:** AC1–AC8.
- **Out:**
  - a Finder file type and double-click import (menu only);
  - sharing watchlists with other people;
  - merging the data of tickets already watched;
  - saving tickets and settings as one all-or-nothing write.

## 5. Implementation
### Automated steps (agent)
All pattern checks match the whole string with
`String.range(of:options: .regularExpression)` and `^…$`, as
`TicketStore.extractTicketKey` does; never `NSRegularExpression.firstMatch`.

1. **`Models/Backup.swift`** (new file; run `xcodegen generate`):
   - `struct Backup: Codable { version, exportedAt, tickets: [WatchedTicket], settings: AppSettings }`.
   - `static func export(tickets:settings:) throws -> Data`: ISO 8601 dates,
     pretty, sorted keys, `customToolPath` set to `nil`; throws "too large"
     when the result exceeds 10,000,000 bytes.
   - `static func read(_ url: URL) throws -> Data`: resolves symlinks, refuses
     anything that is not a regular file (`isRegularFileKey`), then reads at
     most 10,000,001 bytes with `FileHandle.read(upToCount:)` and refuses more
     than 10,000,000.
   - `static func merge(_:into:settings:) throws -> (tickets, settings, Summary)`:
     - decode, and reject `version > 1`;
     - uppercase each key; drop it unless it matches `^[A-Z][A-Z0-9_]+-[0-9]+$`;
     - skip keys already watched or seen earlier in the file;
     - give each imported ticket a new `UUID`;
     - keep a PR only if `URL(string:)` is not nil, the scheme is `https`,
       the host is `github.com` (any case) and the path parses as
       `owner/repo/pull/N`; store the normalized URL;
     - run `migratePRURLs` (made `nonisolated` in `TicketStore`);
     - every imported ticket: `searchPRURLs`, `ssoBlockedOrg` and
       `jiraLoginSite` cleared;
     - imported active tickets: status `.idle`, `pullRequests` emptied,
       `knownPRURLs` kept; archived tickets keep `pullRequests`, `isArchived`
       and status;
     - mapping, prefixes in sorted order: trim and uppercase the prefix and
       drop it unless it matches `^[A-Z][A-Z0-9_]+$`; trim the value and drop
       it if empty or containing `,`, `=` or a line break; store a site as its
       host and drop sites without a dot and orgs with a dot; drop an entry
       unless `parseProjectMap(formatProjectMap(...))` returns it unchanged;
       add only missing entries;
     - settings: poll interval only if 1–30; notifications; base URL and
       default org only when this Mac has none and the backup has a value;
       never `customToolPath`;
     - `Summary` counts added, skipped and dropped items and keeps the dropped
       keys; `summary.alertText` lists up to 10 of them, each shortened to 40
       characters with line breaks shown as ⏎, then "and N more".
   - `static func commit(saveTickets:saveSettings:) -> SaveOutcome`: runs the
     two throwing saves in that order and reports `.saved`, `.ticketsFailed`
     (settings not attempted) or `.settingsFailed`.
2. **`PersistenceService` and `TicketStore`:**
   - `saveTickets` / `saveSettings` become `throws`; their two existing
     callers keep their current behaviour with `try?`;
   - `exportBackup() throws -> Data`;
   - `importBackup(_:) throws -> Summary`, synchronous, merging against the
     live `tickets` with no `await` before assigning: refused in demo mode,
     then `Backup.commit` with the merged values; assign `tickets` only when
     they were saved and `settings` only when they were saved;
     `restartPolling()` when the saved interval changed;
     `Task { await refreshStaleTickets() }` whenever tickets were saved, also
     after `.settingsFailed`. `.ticketsFailed` throws "Nothing was imported:
     tickets could not be saved"; `.settingsFailed` throws "Tickets were
     imported, but settings could not be saved".
3. **`TicketRadarApp`:**
   - `.commands { CommandGroup(after: .newItem) { … } }` with Export Backup… (⇧⌘E) and Import Backup… (⇧⌘I);
   - `NSSavePanel` / `NSOpenPanel` limited to `.json`, default name
     `TicketRadar-backup-<yyyy-MM-dd>.json` (POSIX locale, Gregorian calendar);
   - import reads through `Backup.read`;
   - `NSApp.activate()` first, so the panels open in front;
   - `NSAlert` for the summary and errors, including the too-large export
     ("This backup would be larger than 10 MB, which Import refuses").
4. **`SettingsView`:** move the `onAppear` body into `load(_:)`; add
   `.onChange(of: ticketStore.settings) { _, new in guard new != draft else { return }; load(new) }`.
5. **`DebugSelfCheck`:** T1–T13 (§6), fixtures with whole-second dates.
6. **Docs**, after PR #2 merges and the branch is rebased:
   - README: a Backup section and the two shortcuts;
   - `docs/plans/README.md`: rewrite the import-export row, the order table
     and both warnings, which describe the superseded file-type design.

Commits, files named explicitly, never pushed:
- `fix: Settings reloads when settings change elsewhere` (item 4, revertable alone);
- `feat: export and import a backup from the File menu` (items 1–3, 5, 6).

### Manual steps (user)
- The hands-on test (§7.6).
- Push, PR and merge.

## 6. Tests (self-check, `TR_SELFCHECK=1`)
Each test gets a negative control: break the behaviour, see the named check fail, restore.

| Test | Pins | Negative control |
|------|------|------------------|
| T1 | Round trip keeps archived state and the archived PR snapshot | Drop `pullRequests` from archived tickets on export |
| T2 | A key already watched (other case) is skipped, its data untouched; a key repeated in the file is imported once; imported tickets get new ids, even when the file reuses an existing id | Remove the skip, or keep file ids |
| T3 | A missing prefix ` ops ` is added as `OPS`; an existing site and org are not overwritten; `""`, a dotless site, a dotted org, a value with a line break, `DATA\n` and `"DATA = acme-health\nAPI"` are dropped; ` acme-x ` is stored trimmed; `https://acme-labs.atlassian.net/` is stored as its host; a file with both `data` and `DATA` gives the same result every run; after a `formatProjectMap` → `parseProjectMap` cycle this Mac's `DATA` org is unchanged | Skip normalization, remove the prefix rule or the format → parse check, or match with `NSRegularExpression.firstMatch` |
| T4 | `customToolPath` is neither exported nor imported | Export or copy it |
| T5 | `--web`, `PROJ`, `1A-2` and `DEMO-1\n` are dropped and listed; `MY_PROJ-12` and `demo-1` (as `DEMO-1`) are accepted | Remove key validation, or match with `NSRegularExpression.firstMatch` |
| T6 | PRs with `https://[github.com/a/pull/1`, `file:///x?github.com/pull/1`, `https://evil.example/a/b/pull/1` or `""` are dropped and counted; a valid one is kept, normalized | Remove the URL filter |
| T7 | `version: 2` and non-backup JSON are rejected, inputs unchanged | Remove the version check |
| T8 | An imported active ticket is `.idle`, has no PR snapshot, no search cache and no sign-in banners, and keeps `knownPRURLs`; an imported archived ticket keeps its PR snapshot and archived state, with no search cache and no sign-in banners | Keep the snapshot, the search cache or the banners |
| T9 | Poll interval and notifications come from the backup; intervals `0`, `-1` and `Int.max` keep this Mac's; base URL and default org fill only when empty here; an empty backup value clears nothing | Remove the range check, or overwrite set values |
| T10 | In the temp folder, `Backup.read` refuses a sparse 10,000,001-byte file, a symlink to it and a FIFO (without blocking), and reads a small file | Check `fileSize` on the chosen URL instead of resolving and reading at most 10,000,001 bytes |
| T11 | `commit` with a failing tickets save returns `.ticketsFailed` and never calls the settings save; with a failing settings save it returns `.settingsFailed` | Ignore the error and report `.saved` |
| T12 | With 25 dropped keys the alert text lists 10, then "and 15 more"; a 1,000-character key with a line break is shown as 40 characters with ⏎ | List them all, or in full |
| T13 | `export` of a ticket whose encoded backup exceeds 10,000,000 bytes throws "too large" | Remove the export size check |

## 7. Verification
1. Build, `xcodegen generate` (new file), self-check exit 0.
2. Committed `Info.plist` unchanged.
3. Negative controls T1–T13.
4. Focused security review of the diff: a user-chosen file is untrusted input.
5. CI on the PR.
6. Hands-on test (user, with the agent reading back the results):
   - before: quit every running TicketRadar (dev build and `/Applications`
     copy), then copy `~/Library/Application Support/TicketRadar/`;
   - export; remove one active ticket, one archived ticket and one prefix;
     import; all three come back, nothing else changes, the alert counts match;
   - import with the Settings window open: the merged lines show; typing
     afterwards stays as typed;
   - main window closed: both commands in the File menu; panels and alert in
     front;
   - an invalid file, a `version: 2` file and a file over 10 MB: error,
     nothing changes;
   - a backup with a different poll interval: the new interval is in effect;
   - failed saves: `chflags uchg` on `tickets.json`, import, expect "Nothing
     was imported…", `chflags nouchg`; then the same with `settings.json`,
     expecting "Tickets were imported, but settings could not be saved…";
   - demo mode (`TR_DEMO=1`): import refused;
   - after: quit the app and restore the copied folder, unless you keep the result.

## Review log
### R1 2026-11-06 — adversarial review (fresh subagent, session model; probes in a deleted throwaway clone)
Verdict: not ready, no redesign. All findings folded in above.
- F1 blocker, poll interval unchecked (`Int.max` crash, `0` timer storm) → AC4, R8, T9.
- F2 major, PR URL filter undefined and existing helpers unsafe → step 1, T6.
- F3 major, Settings reload rewrote typed text → step 4 compares with the draft.
- F4 minor, `migratePRURLs` main-actor-isolated → `nonisolated`.
- F5 major, restoring default site and org changed existing tickets → G8.
- F6 major, stale notification burst → G9, AC2, T8.
- F7 minor, overlapping refresh loops → accepted, AC5 reworded.
- F8 minor, file ids trusted, duplicates in the file → new ids, T2.
- F9 minor, mapping not normalized → step 1, T3.
- F10 minor, silent drops; underscore keys → G10, AC6, T5.
- F11 major, verification gaps and real-data risk → §7.6, R11.
- F12 minor, PR #2 overlap and stale plans README → R7, step 6.
- F13 minor, fractional seconds in fixtures → step 5.
- Also folded in: the version rule (R4), a fixed calendar for the file name,
  `customToolPath` left out of the export (G11).

### R2 2026-11-06 — adversarial review (fresh subagent, GPT-6.1-sol; its probe did not start, findings re-checked by the main session)
Verdict: not ready, no redesign. R1's F1, F3–F6, F8, F10, F11, F13 fixed;
F2 and F9 partly fixed, completed by F14 and F15; F7 accepted; F12 waits for
PR #2.
- F14 major, unbounded work: imported `searchPRURLs` reused on a failed search,
  one parallel fetch per URL (source re-checked) → G12, G13, AC8, T8, T10.
- F15 major, a prefix with `=` and a line break overwrote an existing mapping
  after one Settings save (executed by the main session against the app's
  `AppSettings`) → prefix and value rules in AC3, T3.
- F16 major, save errors swallowed, import could report success (source
  re-checked) → G14, step 2, T11.
- Alert size → G15, T12.

### R3 2026-11-06 — adversarial review (fresh subagent, session model; 8 scratch probes run against the app's sources in a deleted throwaway clone)
Verdict: not ready, no redesign; ready once G16 and G17 are folded in. F15
and F16 fixed; F14 partly fixed, completed by F17 and F21; R1 findings not
reopened.
- F17 major, archived tickets kept their search cache: 200,000 URLs fit in
  one archived ticket, and unarchiving during a failed search fans out → G16,
  AC2, T8.
- F18 major, archived tickets kept their sign-in banners, whose Jira command
  has a Copy button → G17, AC2, R14, T8.
- F19 minor, mapping values the Settings text cannot represent (empty org,
  padded, URL site, `data` vs `DATA`) → format → parse check, sorted prefixes,
  AC3, T3.
- F20 minor, `NSRegularExpression` accepted a trailing line break → whole-string
  matching named in step 1, T3, T5.
- F21 minor, size check bypassed by a symlink; FIFO without a size → resolve,
  regular files only, capped read, T10.
- F22 minor, export could exceed the import limit → G18, AC1, T13.
- F23 minor, checks that could not fail (T3 lowercase case, no failed-save
  step, refresh after `.settingsFailed`) → T3, §7.6 with `chflags uchg`,
  step 2 refreshes whenever tickets were saved.
- F24 minor, unbounded key length in the alert → G19, T12.

## Decision gates
- [x] G1 Purpose: back up or move your own setup (user, 2026-11-06)
- [x] G2 Mapping: export it, add only missing prefixes on import (user, 2026-11-06)
- [x] G3 Opening: File menu only (user, 2026-11-06)
- [x] G4 Archived tickets: included, kept archived (user, 2026-11-06)
- [x] G5 Other settings: restore all except Custom PATH; an empty backup value
  clears nothing (user, 2026-11-06; narrowed by G8)
- [x] G6 File type: `.json` (user, 2026-11-06)
- [x] G7 Tickets already watched: skip, keep this Mac's data (user, 2026-11-06)
- [x] G8 Jira base URL and default org: restored only when this Mac has none (user, 2026-11-06, after R1 F5)
- [x] G9 PR snapshots of imported active tickets: dropped (user, 2026-11-06, after R1 F6)
- [x] G10 Keys with underscores: accepted; anything dropped is listed (user, 2026-11-06, after R1 F10)
- [x] G11 Custom PATH on export: left out of the file (user, 2026-11-06)
- [x] G12 File size: refuse files over 10 MB before reading them (user, 2026-11-06, after R2 F14)
- [x] G13 Search cache of imported active tickets: dropped (user, 2026-11-06, after R2 F14; widened by G16)
- [x] G14 Failed save: error alert naming the part not saved; no all-or-nothing write (user, 2026-11-06, after R2 F16)
- [x] G15 Dropped entries in the alert: first 10, then "and N more" (user, 2026-11-06)
- [x] G16 Search cache: dropped on every imported ticket, archived included (user, 2026-11-06, after R3 F17)
- [x] G17 Sign-in banners: cleared on every imported ticket (user, 2026-11-06, after R3 F18)
- [x] G18 Export over 10 MB: refused with an explanation (user, 2026-11-06, after R3 F22)
- [x] G19 Keys in the alert: each shortened to 40 characters, line breaks shown as ⏎ (user, 2026-11-06, after R3 F24)

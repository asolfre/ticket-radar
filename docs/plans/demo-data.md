# Plan: Anonymized Screenshots via a DEBUG Demo Seed

## Goal
Produce anonymized marketing screenshots (`screenshots/main-window.png`, `menu-bar.png`,
`notification.png`, `archived.png`) for a native macOS SwiftUI menu bar app, without
exposing real Jira/GitHub organizational data.

## Context
- **App type:** Native macOS SwiftUI menu bar app (not web/mobile) — no Playwright/browser to script.
- **Data source:** Fetched live at runtime by shelling out to `acli` (Jira) and `gh` (GitHub).
  No DB, no bundled fixtures. Persisted as JSON in
  `~/Library/Application Support/TicketRadar/{tickets.json,settings.json}`.
- **Key launch behaviors (`TicketStore.swift:12-23`):**
  - `refreshStaleTickets()` only re-fetches tickets whose status is `.idle` or `.error`
    (`TicketStore.swift:204-219`). If the fixture uses `.ready`, no live `acli`/`gh` call
    overwrites the fake data.
  - `startPolling()` schedules the first refresh only *after* one poll interval
    (`TicketStore.swift:27-35`).
- **Shared state:** A single `TicketStore` instance backs the menu bar, window, and settings
  (`TicketRadarApp.swift:5`).
- **Notifications:** Normally only fire on a state-change diff during polling
  (`NotificationService.detectAndNotify`, `NotificationService.swift:19`).

## Data to Anonymize
Ticket keys/titles, GitHub org in PR URLs, repo names, reviewer usernames, review comment
bodies (`WatchedTicket.swift:12-13`, `PullRequest.swift:43-46`, `PullRequest.swift:27-39`).

## Chosen Approach: Option C — Temporary DEBUG demo seed (gated + reusable)
Everything gated behind `#if DEBUG` + a `TR_DEMO=1` environment variable so production
behavior is untouched. Code stays in the repo (inert without the env var) for future reuse.

> **Correction to §2 below:** gating only `startPolling()` / `refreshStaleTickets()` is
> **not** sufficient. Every mutating path in `TicketStore` funnels through `save()`, so an
> accidental Cmd+R (or archive, or add) in demo mode would overwrite the user's real
> `tickets.json` with demo content. Demo mode must also make `save()`, `updateSettings()`
> and every refresh entry point a no-op. As shipped, demo mode never reads or writes
> Application Support and never shells out at all.

### 1. Add a demo fixture (new file, type-safe)
Create `TicketRadar/Sources/DemoData.swift` that builds a realistic **fake**
`[WatchedTicket]` using the model initializers directly (no JSON enum guesswork). Cover every
UI state the screenshots need:
- **Active tickets** with varied PR states:
  - Approved + all-green CI + merge CLEAN
  - Changes-requested + unresolved threads (red actionable dot) + failing CI + merge BLOCKED
  - Mixed CI (`.mixed(passed:total:)`), pending review
  - A merged PR and a closed PR
  - Populated `comments: [ReviewComment]` with fake authors + benign body text
    (for `TicketDetailView`)
  - `status: .ready` so launch-time `refreshStaleTickets()` never calls `acli`/`gh`
  - Fake but realistic `createdAt`/`mergedAt`/`firstReviewAt` so age/review-wait columns render
- **One archived ticket** (`isArchived: true`) for `archived.png`
- Anonymized values throughout: keys like `DEMO-4821`, titles like "Add rate limiting to auth
  service", repos `web-app`/`api-gateway`/`billing-service`, PR URLs
  `https://github.com/acme-labs/...`, authors `alex.chen`, `sam.rivera`.

### 2. Wire the seed into `TicketStore.init()` (`TicketStore.swift:12-23`)
```swift
if ProcessInfo.processInfo.environment["TR_DEMO"] == "1" {
    self.tickets = DemoData.tickets
    self.settings = AppSettings(pollIntervalMinutes: 30, notificationsEnabled: true,
                                jiraBaseURL: "https://acme-labs.atlassian.net")
    // skip startPolling()/refreshStaleTickets() -> no network, no overwrite
} else {
    // existing real path
}
```
This avoids touching `tickets.json` entirely — the real watchlist is never loaded or clobbered.

### 3. On-demand notification trigger (for `notification.png`)
In demo mode, after a short delay fire a real app notification so the banner looks authentic
(reusing `NotificationService`, `NotificationService.swift:109`). Add a tiny
`NotificationService.sendDemo()` (or call `detectAndNotify` with a crafted old/new pair)
invoked once from the demo init after `requestPermission()`. Produces a genuine macOS banner,
e.g. `DEMO-4821: PR #142 approved`.

### 4. Build & run in demo mode
```bash
xcodegen generate
xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
           -destination 'platform=macOS' build

open --env TR_DEMO=1 -n --fresh \
  "$(xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
                -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
     | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/TicketRadar.app"
```

Two corrections to note:
- **`TR_DEMO=1 open ...` does not work.** That sets the variable for `open`
  itself, which does not forward its environment to the launched app. Use
  `open --env TR_DEMO=1`. Running from Xcode with the scheme env var set is the
  other option.
- **Don't glob for `TicketRadar-*`.** Stale DerivedData folders from earlier
  checkouts also match, so the glob can launch an old build. Ask `xcodebuild`
  for `BUILT_PRODUCTS_DIR` as above.

### 5. Capture screenshots into `screenshots/`

The app launches without a window (the `Window` scene isn't restored under
`--fresh`). Click the menu bar antenna icon → **Open Window** first.
`DEMO-4821` is preselected, so the detail pane is populated immediately.

```bash
cd <repo root>
screencapture -w -o screenshots/main-window.png   # then click the window
screencapture -w -o screenshots/archived.png      # select the archived ticket first
screencapture -i screenshots/menu-bar.png         # open the popover, drag a region
screencapture -i screenshots/notification.png     # when the banner appears
```

The demo notification fires ~6s after launch (`DEMO-4821: PR #142 approved`).
If it doesn't appear, notification permission hasn't been granted yet — grant it
on the first run, quit, and relaunch.

> **Banner while TicketRadar is in front.** Every notification gets a unique
> identifier, so the demo banner shows on every run, even with TicketRadar
> frontmost. (macOS shows no banner for a notification that *replaces* one
> with the same identifier while the app is in front.) Each demo run leaves
> one more entry in Notification Center.

> **`screencapture` needs Screen Recording permission.** Without it macOS
> silently returns only the wallpaper and menu bar chrome — no app windows, no
> status icons — so the captures look inexplicably empty. Grant it to Terminal
> (or whichever app runs the command) under
> System Settings → Privacy & Security → Screen Recording. A **locked** screen
> also returns an all-black image, even with the permission.

#### Captured 2026-10-19 (no clicks by hand)
With Screen Recording **and** Accessibility granted to the app running the
shell, every shot was scripted: windows captured by ID
(`screencapture -o -l <CGWindowID>`), clicks posted with `CGEvent`, the main
window moved to the Retina display via the Accessibility API for 2× output.
`notification.png` takes its pixels from a full-screen capture and its
rounded-corner transparency from the banner window alone — the banner window
by itself renders flat grey, because its blurred backdrop isn't part of it.

### 6. Lifetime
Keep the demo code in the repo behind `#if DEBUG` + `TR_DEMO` (inert in normal use, reusable
for future screenshots). Confirm `git status` shows only intended changes before any commit.

Once the PNGs exist, remove the "Screenshots pending" note from `README.md`.

## Files Touched
- New: `TicketRadar/Sources/DemoData.swift`
- Edit: `TicketRadar/Sources/ViewModels/TicketStore.swift` (demo branch in `init`,
  plus `isDemoMode` guards on `save`, `updateSettings`, `startPolling`,
  `refreshTicket`, `refreshAll`, `refreshStaleTickets`)
- Edit: `TicketRadar/Sources/Services/NotificationService.swift` (`sendDemo()` helper)
- New assets: `screenshots/*.png`

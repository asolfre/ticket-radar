# AGENTS.md

## Building

**`project.yml` + XcodeGen is the only build path.** There is no
`Package.swift` — SwiftPM is not supported and `swift build` will not work.
The app is built via the Xcode project generated from `project.yml`.

```bash
# If the project file is stale or files were added/removed:
xcodegen generate

# Build (DEVELOPER_DIR makes it work even when `xcode-select` points at the
# Command Line Tools instead of Xcode):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
             -destination 'platform=macOS' build
```

### Gotchas
- **Don't reintroduce `Package.swift`.** It was removed deliberately: SwiftPM's
  stricter default concurrency checking reported MainActor-isolation "errors"
  in `AddTicketSheet.swift` / `TicketRadarApp.swift` that do NOT occur in the
  real Xcode build (Swift 5 language mode). Never verify with `swift build`.
- **`xcodebuild` fails with "requires Xcode"** when the active developer
  directory is the Command Line Tools. Use the per-command `DEVELOPER_DIR=...`
  override above, pointing at your Xcode.app, rather than `sudo xcode-select -s`
  (avoids a global change).
- **Only edited existing files?** No need to re-run `xcodegen generate` —
  the existing `.xcodeproj` already references them. Regenerate only when
  adding/removing/renaming source files.
- **Universal Release builds need `-destination 'generic/platform=macOS'`.**
  With `'platform=macOS'` Xcode builds only the current Mac's architecture,
  even in Release, despite `ARCHS = arm64 x86_64`.

### Build output
The app lands in DerivedData, not the repo. **Don't glob for
`TicketRadar-*`** — stale DerivedData folders from earlier checkouts also
match, so the glob can resolve to an old build. Ask xcodebuild instead:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
             -destination 'platform=macOS' -showBuildSettings \
  | awk '/ BUILT_PRODUCTS_DIR/{print $3}'
```

To launch the build you just made:

```bash
open -n "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
             -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/TicketRadar.app"
```

### Verify: self-check
A green build does not run anything. After building, run the DEBUG
self-check — it exits **0** when every check passes, **1** with a
`TR_SELFCHECK FAILED: …` line on the first failure, and never opens the UI:

```bash
TR_SELFCHECK=1 "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TicketRadar.xcodeproj -scheme TicketRadar \
             -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/TicketRadar.app/Contents/MacOS/TicketRadar"; echo "exit=$?"
```

Checks live in `TicketRadar/Sources/DebugSelfCheck.swift`; add one there for
any new non-trivial logic. Code it calls must not need the main actor:
`waitFor` blocks the main thread, so a main-actor hop deadlocks (the run hangs
instead of failing).

### Versioning
Bump `CFBundleShortVersionString` and `CFBundleVersion` under `info.properties`
in `project.yml` (the only version source; there are no `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` build settings). Then `xcodegen generate` and commit
the regenerated `TicketRadar/Resources/Info.plist` too. Releases get an
annotated tag (`v0.1.0`).

### CI and releases
`.github/workflows/ci.yml` checks every push to `main` and every pull request;
`.github/workflows/release.yml` builds and publishes a release for a `v*` tag.
Both run on the **preview** `xcode-27` image with Xcode pinned to 27.1 (the
local version) through `DEVELOPER_DIR`. If that image queues repeatedly or
breaks, fall back in **both** files at once: `runs-on: macos-26`,
`DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer`, and the
version check pattern `'^Xcode 26\.6'`.

To release: bump the version (above), commit, push `main` and wait for CI to
pass (the release job does not re-run CI's checks), then
`git tag -a vX.Y.Z -m "<release notes>"` and push the tag. Push only when the
user asks.

## Publishing
This repository is public. Push only when the user asks.

**Never commit real ticket keys, Jira sites, GitHub org or repo names, or
other employer-internal details** — not in code, comments, test data, docs,
plans or commit messages. Use the fictional names already in the repo: Jira
`acme.atlassian.net` / `acme-labs.atlassian.net`, orgs `acme-data` /
`acme-health`, prefixes `DATA` / `API` / `OPS`, and the `DEMO-…` tickets
from `DemoData.swift`. Investigations of real tickets belong outside the
repository.

## Prerequisites
`gh` and `acli` must be installed and authenticated (the app shells out to
both). See README.

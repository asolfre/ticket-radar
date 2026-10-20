# Export / Import — Implementation Plan

## Summary

Export the watchlist as a `.ticketradar` file (JSON with ticket keys). Import
merges new tickets into the existing watchlist, skipping duplicates.
Double-clicking a `.ticketradar` file opens the app and imports automatically.

---

## File Format

`.ticketradar` — a JSON file:

```json
{
  "version": 1,
  "exportedAt": "2026-06-08T16:30:00Z",
  "tickets": ["DEMO-4821", "DEMO-4796"],
  "archived": ["DEMO-4502"]
}
```

- `tickets` — active ticket keys
- `archived` — archived ticket keys
- On import, ALL keys (both arrays) are added as **active** tickets. Recipients
  decide what to archive themselves.

---

## Export Flow

1. User clicks **File -> Export Watchlist...** (Cmd+Shift+E)
2. `NSSavePanel` opens, default filename: `TicketRadar-export.ticketradar`
3. App writes JSON with active keys in `tickets`, archived keys in `archived`
4. Done

---

## Import Flow

### Via menu

1. User clicks **File -> Import Watchlist...** (Cmd+Shift+I)
2. `NSOpenPanel` opens, filtered to `.ticketradar` files
3. App reads JSON, extracts all ticket keys from both `tickets` and `archived`
4. For each key: if not already in watchlist -> add as active (triggers auto-refresh)
5. Show alert: "Imported X tickets. Y already existed (skipped)."

### Via double-click (file association)

1. User double-clicks a `.ticketradar` file in Finder
2. macOS opens TicketRadar (or brings it to front)
3. App receives URL via `onOpenURL` / `NSApplicationDelegate`
4. Same merge logic as menu import
5. Show result alert

---

## Implementation Steps

| # | Task | File |
|---|------|------|
| 1 | Define `ExportData` struct (version, exportedAt, tickets, archived) | `Models/ExportData.swift` (new) |
| 2 | Add `exportTickets() -> Data` and `importTickets(from: Data) -> ImportResult` | `ViewModels/TicketStore.swift` |
| 3 | Register `.ticketradar` UTI + document type | `Info.plist` + `project.yml` |
| 4 | Add File menu commands (Export / Import) | `TicketRadarApp.swift` |
| 5 | Handle `onOpenURL` for double-click file association | `TicketRadarApp.swift` |
| 6 | Show import result alert | `Views/MainWindowView.swift` |

---

## Model: ExportData

```swift
struct ExportData: Codable {
    let version: Int
    let exportedAt: Date
    let tickets: [String]
    let archived: [String]

    static let currentVersion = 1
}
```

---

## TicketStore Methods

```swift
// Export
func exportData() -> Data {
    let export = ExportData(
        version: ExportData.currentVersion,
        exportedAt: Date(),
        tickets: activeTickets.map(\.ticketKey),
        archived: archivedTickets.map(\.ticketKey)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try! encoder.encode(export)
}

// Import
struct ImportResult {
    let imported: Int
    let skipped: Int
}

func importTickets(from data: Data) throws -> ImportResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let export = try decoder.decode(ExportData.self, from: data)

    if export.version > ExportData.currentVersion {
        throw ImportError.newerVersion
    }

    let allKeys = export.tickets + export.archived
    var imported = 0
    var skipped = 0

    for key in allKeys {
        let upper = key.uppercased()
        if tickets.contains(where: { $0.ticketKey == upper }) {
            skipped += 1
        } else {
            let ticket = WatchedTicket(ticketKey: upper)
            tickets.append(ticket)
            imported += 1
            Task { await refreshTicket(id: ticket.id) }
        }
    }

    save()
    return ImportResult(imported: imported, skipped: skipped)
}
```

---

## Info.plist Additions

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>TicketRadar Export</string>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>com.asolfre.ticketradar.export</string>
    </array>
  </dict>
</array>

<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key>
    <string>com.asolfre.ticketradar.export</string>
    <key>UTTypeDescription</key>
    <string>TicketRadar Watchlist</string>
    <key>UTTypeConformsTo</key>
    <array>
      <string>public.json</string>
    </array>
    <key>UTTypeTagSpecification</key>
    <dict>
      <key>public.filename-extension</key>
      <array>
        <string>ticketradar</string>
      </array>
    </dict>
  </dict>
</array>
```

---

## App Commands (File Menu)

```swift
.commands {
    CommandGroup(after: .newItem) {
        Divider()
        Button("Export Watchlist...") { exportAction() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        Button("Import Watchlist...") { importAction() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}
```

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Import file with unknown/invalid keys | Add them -- they'll show errors on refresh |
| Corrupted/invalid JSON | Alert: "Could not read file. Invalid format." |
| Version > 1 | Alert: "This file requires a newer version of TicketRadar." |
| Empty tickets array | Alert: "No tickets found in file." |
| All keys already exist | Alert: "0 imported. X already existed (skipped)." |
| Double-click while app is closed | App launches, imports, shows result |

---

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Export Watchlist | Cmd+Shift+E |
| Import Watchlist | Cmd+Shift+I |

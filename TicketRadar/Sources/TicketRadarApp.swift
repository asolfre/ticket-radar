import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
struct TicketRadarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var ticketStore = TicketStore()

    init() {
        #if DEBUG
        if DebugSelfCheck.isEnabled { DebugSelfCheck.run() }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(ticketStore: ticketStore)
                .frame(width: 300, height: 400)
        } label: {
            MenuBarLabel(actionableCount: ticketStore.actionableCount, appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Window("TicketRadar", id: "main") {
            MainWindowView(ticketStore: ticketStore)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 650)
        .commands {
            CommandGroup(after: .importExport) {
                Button("Export Backup…") { BackupPanels.export(ticketStore) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Backup…") { BackupPanels.import(ticketStore) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(ticketStore: ticketStore, onSettingsChanged: {
                ticketStore.restartPolling()
            })
        }
    }
}

/// Reopens the main window when the Dock icon is clicked, and shows
/// notification banners while TicketRadar is the frontmost app.
///
/// SwiftUI handles Dock "reopen" only for `WindowGroup`; the main window is a
/// single `Window`, so once closed a Dock click did nothing. AppKit has no
/// access to SwiftUI's `openWindow`, so a view hands it over in `openMainWindow`.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var openMainWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return true
    }

    /// Without this, macOS shows no banner for the frontmost app: a "PR merged"
    /// for another ticket went silently into Notification Center while the
    /// TicketRadar window was in front. (macOS also skips this call for a
    /// notification that replaces one with the same identifier, which is why
    /// `NotificationService.send` makes every identifier unique.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Save and open panels and result alerts for the File menu's backup commands.
/// AppKit panels and alerts work with the main window closed.
@MainActor
enum BackupPanels {
    static func export(_ store: TicketStore) {
        NSApp.activate()
        do {
            let data = try Backup.export(tickets: store.tickets, settings: store.settings)
            let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "TicketRadar-backup-\(date).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            alert("Backup exported", "Saved \(store.tickets.count) tickets and your settings to \(url.lastPathComponent).")
        } catch {
            alert("Export failed", error.localizedDescription, style: .warning)
        }
    }

    static func `import`(_ store: TicketStore) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try store.importBackup(try Backup.read(url))
            alert("Backup imported", summary.alertText)
        } catch {
            alert("Import failed", error.localizedDescription, style: .warning)
        }
    }

    private static func alert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }
}

/// Menu bar label with badge indicator
///
/// Also hands `openWindow` to the app delegate: the label is rendered at launch
/// and stays alive, unlike the menu bar panel, which is built on first open.
struct MenuBarLabel: View {
    let actionableCount: Int
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if actionableCount > 0 {
                Label {
                    Text("TicketRadar")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .primary)
                }
            } else {
                Label("TicketRadar", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .onAppear {
            appDelegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}

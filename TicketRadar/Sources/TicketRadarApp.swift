import SwiftUI
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

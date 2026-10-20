import Foundation
import UserNotifications

/// Sends macOS notifications when PR state changes are detected.
@MainActor
enum NotificationService {

    /// Request notification permission (call once on app launch)
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    /// Compare old and new ticket state, send notifications for meaningful changes.
    /// Uses `knownPRURLs` to prevent false "new PR" notifications from transient fetch failures.
    static func detectAndNotify(old oldTicket: WatchedTicket, new newTicket: WatchedTicket) {
        guard !oldTicket.pullRequests.isEmpty else { return }

        for newPR in newTicket.pullRequests {
            let key = GitHubService.prKey(newPR.url)
            guard let oldPR = oldTicket.pullRequests.first(where: { GitHubService.prKey($0.url) == key }) else {
                // Only notify "new PR" if we've NEVER seen this URL before.
                // This prevents false notifications when a PR temporarily fails to fetch
                // in one cycle but succeeds in the next.
                if !oldTicket.knownPRURLs.contains(where: { GitHubService.prKey($0) == key }) {
                    send(
                        title: "\(newTicket.ticketKey): New PR linked",
                        body: "#\(newPR.number) in \(newPR.repository) — \(newPR.title)",
                        identifier: "new-pr-\(newPR.url)"
                    )
                }
                continue
            }

            // State changed (open → merged, open → closed)
            if oldPR.state != newPR.state {
                switch newPR.state {
                case .merged:
                    send(
                        title: "\(newTicket.ticketKey): PR #\(newPR.number) merged",
                        body: "\(newPR.repository) — \(newPR.title)",
                        identifier: "merged-\(newPR.url)"
                    )
                case .closed:
                    send(
                        title: "\(newTicket.ticketKey): PR #\(newPR.number) closed",
                        body: "\(newPR.repository) — \(newPR.title)",
                        identifier: "closed-\(newPR.url)"
                    )
                case .open:
                    break // reopened — unusual, skip notification
                }
            }

            // Review decision changed
            if oldPR.reviewDecision != newPR.reviewDecision {
                switch newPR.reviewDecision {
                case "APPROVED":
                    send(
                        title: "\(newTicket.ticketKey): PR #\(newPR.number) approved",
                        body: "\(newPR.repository)",
                        identifier: "approved-\(newPR.url)"
                    )
                case "CHANGES_REQUESTED":
                    send(
                        title: "\(newTicket.ticketKey): Changes requested on PR #\(newPR.number)",
                        body: "\(newPR.repository)",
                        identifier: "changes-\(newPR.url)"
                    )
                default:
                    break
                }
            }

            // CI status changed to failing
            if oldPR.ciStatus != .failing && newPR.ciStatus == .failing {
                send(
                    title: "\(newTicket.ticketKey): CI failed on PR #\(newPR.number)",
                    body: "\(newPR.repository)",
                    identifier: "ci-fail-\(newPR.url)"
                )
            }

            // CI status changed to passing (recovered)
            if oldPR.ciStatus == .failing && newPR.ciStatus == .passing {
                send(
                    title: "\(newTicket.ticketKey): CI green on PR #\(newPR.number)",
                    body: "\(newPR.repository)",
                    identifier: "ci-pass-\(newPR.url)"
                )
            }

            // New review comments
            if newPR.comments.count > oldPR.comments.count && newPR.state == .open {
                let newCount = newPR.comments.count - oldPR.comments.count
                send(
                    title: "\(newTicket.ticketKey): \(newCount) new comment\(newCount > 1 ? "s" : "") on PR #\(newPR.number)",
                    body: "\(newPR.repository)",
                    identifier: "comments-\(newPR.url)-\(newPR.comments.count)"
                )
            }
        }
    }

    // MARK: - Demo

    #if DEBUG
    /// Fire a representative notification so the banner can be screenshotted.
    ///
    /// Goes through the same `send` path as real notifications, so the captured
    /// banner is genuine rather than mocked up. Only reachable in demo mode.
    static func sendDemo() {
        send(
            title: "DEMO-4821: PR #142 approved",
            body: "api-gateway — [DEMO-4821] Add rate limiting middleware",
            identifier: "demo-approved-142"
        )
    }
    #endif

    // MARK: - Private

    /// Every request gets a unique identifier. Reusing one (e.g. a second
    /// "CI failed" on the same PR) replaces the copy still in Notification
    /// Center, and macOS shows no banner for such a replacement while
    /// TicketRadar is frontmost. Repeats now appear as separate entries.
    private static func send(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(identifier)-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
}

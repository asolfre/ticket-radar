import SwiftUI

struct TicketDetailView: View {
    let ticket: WatchedTicket
    @Bindable var ticketStore: TicketStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Archive banner
                if ticket.isArchived {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox.fill")
                        Text("This ticket is archived. PR data is a frozen snapshot.")
                        Spacer()
                        Button("Unarchive") {
                            ticketStore.unarchiveTicket(id: ticket.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.orange)
                }

                // Header
                headerSection

                Divider()

                // Summary bar
                if !ticket.pullRequests.isEmpty {
                    summaryBar
                    Divider()
                }

                // PR Table
                if ticket.pullRequests.isEmpty {
                    emptyState
                } else {
                    prTableSection
                    Divider()
                    commentsSection
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await ticketStore.refreshTicket(id: ticket.id)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(ticket.status == .loading || ticket.isArchived)
            }
        }
    }

    // MARK: - Header

    @MainActor @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ticket.ticketKey)
                    .font(.title.bold())

                if let jiraURL = ticketStore.settings.browseURL(for: ticket.ticketKey) {
                    Link(destination: jiraURL) {
                        Label("Open in Jira", systemImage: "arrow.up.right.square")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                Spacer()

                if let lastRefreshed = ticket.lastRefreshed {
                    Text("Last refreshed: \(lastRefreshed, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let title = ticket.title {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if case .error(let message) = ticket.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.top, 4)
            }

            if let org = ticket.ssoBlockedOrg {
                SSOHelpView(orgs: [org])
            }

            if let site = ticket.jiraLoginSite {
                JiraLoginHelpView(site: site)
            }
        }
    }

    // MARK: - Summary Bar

    @ViewBuilder
    private var summaryBar: some View {
        HStack(spacing: 16) {
            summaryItem(
                count: ticket.openPRCount,
                label: "Open",
                color: .green
            )
            summaryItem(
                count: ticket.mergedPRCount,
                label: "Merged",
                color: .purple
            )
            summaryItem(
                count: ticket.closedPRCount,
                label: "Closed",
                color: .red
            )

            Spacer()

            let needsReview = ticket.pullRequests.filter {
                $0.state == .open && $0.reviewDecision == "REVIEW_REQUIRED"
            }.count
            if needsReview > 0 {
                Label("\(String(needsReview)) needs review", systemImage: "eye")
                    .foregroundStyle(.orange)
            }

            let failingCI = ticket.pullRequests.filter {
                $0.state == .open && $0.ciStatus == .failing
            }.count
            if failingCI > 0 {
                Label("\(String(failingCI)) CI failing", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    private func summaryItem(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(count)")
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - PR Table

    @ViewBuilder
    private var prTableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pull Requests")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                // Header row
                GridRow {
                    Text("Repository").bold()
                    Text("PR").bold()
                    Text("State").bold()
                    Text("Review").bold()
                    Text("Threads").bold()
                    Text("CI").bold()
                    Text("Merge").bold()
                    Text("Opened").bold()
                    Text("Wait").bold()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(9)

                ForEach(ticket.pullRequests) { pr in
                    GridRow {
                        Text(pr.repository)
                            .lineLimit(1)

                        Link("#" + String(pr.number), destination: URL(string: pr.url)!)

                        prStateBadge(pr.state)

                        reviewBadge(pr.reviewDecision)

                        threadsBadge(total: pr.totalThreads, unresolved: pr.unresolvedThreads, state: pr.state)

                        ciBadge(pr.ciStatus)

                        Text(pr.state == .merged ? "--" : (pr.mergeStatus ?? "--"))
                            .foregroundStyle(.secondary)

                        Text(pr.openedAgeText)
                            .foregroundStyle(.secondary)

                        Text(pr.reviewWaitText)
                            .foregroundStyle(pr.isWaitingForReview ? .orange : .secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func prStateBadge(_ state: PRState) -> some View {
        switch state {
        case .open:
            Text("OPEN")
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.green)
        case .merged:
            Text("MERGED")
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.purple)
        case .closed:
            Text("CLOSED")
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func reviewBadge(_ decision: String?) -> some View {
        switch decision {
        case "APPROVED":
            Text("Approved")
                .foregroundStyle(.green)
        case "CHANGES_REQUESTED":
            Text("Changes req.")
                .foregroundStyle(.orange)
        case "REVIEW_REQUIRED":
            Text("Pending")
                .foregroundStyle(.yellow)
        default:
            Text("--")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func threadsBadge(total: Int, unresolved: Int, state: PRState) -> some View {
        if state == .merged {
            Text("--")
                .foregroundStyle(.secondary)
        } else if unresolved > 0 {
            Text(verbatim: "\(unresolved)/\(total)")
                .foregroundStyle(.orange)
        } else {
            Text(verbatim: "\(total)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ciBadge(_ status: CIStatus) -> some View {
        switch status {
        case .passing:
            Text("All green")
                .foregroundStyle(.green)
        case .failing:
            Text("Failing")
                .foregroundStyle(.red)
        case .pending:
            Text("Pending")
                .foregroundStyle(.yellow)
        case .mixed(let passed, let total):
            Text(verbatim: "\(passed)/\(total)")
                .foregroundStyle(.orange)
        case .unknown:
            Text("--")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Comments Section

    @ViewBuilder
    private var commentsSection: some View {
        let openPRsWithComments = ticket.pullRequests.filter {
            $0.state == .open && !$0.comments.isEmpty
        }

        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews & Comments")
                .font(.headline)

            if openPRsWithComments.isEmpty {
                Text("No review comments on open PRs.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(openPRsWithComments) { pr in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(verbatim: "\(pr.repository) #\(pr.number)")
                                .font(.subheadline.bold())
                            Text("(\(pr.state.rawValue))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(pr.comments) { comment in
                            HStack(alignment: .top, spacing: 8) {
                                Text("@\(comment.author)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.blue)

                                Text("(\(comment.reviewState))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(comment.body)
                                    .font(.caption)
                                    .lineLimit(3)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No PRs Found", systemImage: "doc.text.magnifyingglass")
        } description: {
            switch ticket.status {
            case .idle:
                Text("Press Refresh to fetch PR information for this ticket.")
            case .loading:
                Text("Loading...")
            case .ready:
                Text("No pull requests linked to this ticket.")
            case .error(let msg):
                Text(msg)
            }
        }
    }
}

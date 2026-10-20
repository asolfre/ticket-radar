import SwiftUI

struct TicketRowView: View {
    let ticket: WatchedTicket

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ticket.ticketKey)
                        .font(.headline)
                        .lineLimit(1)

                    if ticket.hasActionItems {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let title = ticket.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !ticket.pullRequests.isEmpty {
                    HStack(spacing: 6) {
                        statusBadge(count: ticket.openPRCount, label: "open", color: .green)
                        statusBadge(count: ticket.mergedPRCount, label: "merged", color: .purple)
                        statusBadge(count: ticket.closedPRCount, label: "closed", color: .red)
                    }
                    .font(.caption2)
                }
            }

            Spacer()

            statusIndicator
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch ticket.status {
        case .idle:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusBadge(count: Int, label: String, color: Color) -> some View {
        if count > 0 {
            Text(verbatim: "\(count) \(label)")
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(color)
        }
    }
}

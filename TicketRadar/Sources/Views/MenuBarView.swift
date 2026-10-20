import SwiftUI

struct MenuBarView: View {
    @Bindable var ticketStore: TicketStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("TicketRadar")
                    .font(.headline)
                Spacer()
                if ticketStore.actionableCount > 0 {
                    Text("\(ticketStore.actionableCount)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Ticket list
            if ticketStore.activeTickets.isEmpty {
                Text("No active tickets")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ticketStore.activeTickets) { ticket in
                            menuTicketRow(ticket)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Actions
            VStack(spacing: 4) {
                Button {
                    // A menu bar panel click does not activate the app, so
                    // without this the window can open behind the front app.
                    NSApp.activate()
                    openWindow(id: "main")
                } label: {
                    Label("Open Window", systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Button {
                    Task {
                        await ticketStore.refreshAll()
                    }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func menuTicketRow(_ ticket: WatchedTicket) -> some View {
        HStack(spacing: 8) {
            if ticket.hasActionItems {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            } else if ticket.status == .loading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(.clear)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(ticket.ticketKey)
                    .font(.callout.bold())
                    .lineLimit(1)
                if let title = ticket.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !ticket.pullRequests.isEmpty {
                Text(verbatim: "\(ticket.pullRequests.count) PRs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

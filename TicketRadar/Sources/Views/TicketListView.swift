import SwiftUI

struct TicketListView: View {
    @Bindable var ticketStore: TicketStore
    @Binding var showingAddSheet: Bool
    @State private var isArchivedExpanded = true

    var body: some View {
        List(selection: $ticketStore.selectedTicketID) {
            if ticketStore.activeTickets.isEmpty && ticketStore.archivedTickets.isEmpty {
                Text("No tickets watched")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                // Active tickets section
                if !ticketStore.activeTickets.isEmpty {
                    Section("Watching") {
                        ForEach(ticketStore.activeTickets) { ticket in
                            TicketRowView(ticket: ticket)
                                .tag(ticket.id)
                                .contextMenu {
                                    Button {
                                        Task {
                                            await ticketStore.refreshTicket(id: ticket.id)
                                        }
                                    } label: {
                                        Label("Refresh", systemImage: "arrow.clockwise")
                                    }

                                    if let jiraURL = ticketStore.settings.browseURL(for: ticket.ticketKey) {
                                        Link(destination: jiraURL) {
                                            Label("Open in Jira", systemImage: "safari")
                                        }
                                    }

                                    Divider()

                                    Button {
                                        ticketStore.archiveTicket(id: ticket.id)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }

                                    Button("Remove", role: .destructive) {
                                        ticketStore.removeTicket(id: ticket.id)
                                    }
                                }
                        }
                    }
                }

                // Archived tickets section
                if !ticketStore.archivedTickets.isEmpty {
                    Section(isExpanded: $isArchivedExpanded) {
                        ForEach(ticketStore.archivedTickets) { ticket in
                            TicketRowView(ticket: ticket)
                                .tag(ticket.id)
                                .opacity(0.7)
                                .contextMenu {
                                    Button {
                                        ticketStore.unarchiveTicket(id: ticket.id)
                                    } label: {
                                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                                    }

                                    if let jiraURL = ticketStore.settings.browseURL(for: ticket.ticketKey) {
                                        Link(destination: jiraURL) {
                                            Label("Open in Jira", systemImage: "safari")
                                        }
                                    }

                                    Divider()

                                    Button("Remove", role: .destructive) {
                                        ticketStore.removeTicket(id: ticket.id)
                                    }
                                }
                        }
                    } header: {
                        Label("Archived", systemImage: "archivebox")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .navigationTitle("Tickets")
        .onDeleteCommand {
            if let selectedID = ticketStore.selectedTicketID {
                ticketStore.removeTicket(id: selectedID)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Ticket", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Spacer()

                Text(verbatim: "\(ticketStore.activeTickets.count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            .background(.bar)
        }
    }
}

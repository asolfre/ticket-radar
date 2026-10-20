import SwiftUI

struct MainWindowView: View {
    @Bindable var ticketStore: TicketStore
    @State private var showingAddSheet = false

    var body: some View {
        NavigationSplitView {
            TicketListView(
                ticketStore: ticketStore,
                showingAddSheet: $showingAddSheet
            )
        } detail: {
            if let ticket = ticketStore.selectedTicket {
                TicketDetailView(ticket: ticket, ticketStore: ticketStore)
            } else {
                ContentUnavailableView(
                    "No Ticket Selected",
                    systemImage: "ticket",
                    description: Text("Select a ticket from the sidebar or add one with \(Image(systemName: "plus"))")
                )
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddTicketSheet(ticketStore: ticketStore)
        }
    }
}

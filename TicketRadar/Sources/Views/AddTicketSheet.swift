import SwiftUI

struct AddTicketSheet: View {
    @Bindable var ticketStore: TicketStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Ticket to Watch")
                .font(.headline)

            Text("Enter a Jira ticket key or full URL")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("e.g. PROJ-7328 or a Jira ticket URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    addTicket()
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addTicket()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    private func addTicket() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = TicketStore.extractTicketKey(from: trimmed)
        guard !key.isEmpty else {
            errorMessage = "Could not extract a valid ticket key from the input."
            return
        }

        if ticketStore.tickets.contains(where: { $0.ticketKey.uppercased() == key.uppercased() }) {
            errorMessage = "\(key) is already in your watchlist."
            return
        }

        ticketStore.addTicket(input: trimmed)
        dismiss()
    }
}

import SwiftUI
import EmailKit

/// A basic compose window: pick the sending account, fill To/Subject/Body, and
/// send via EmailKit's SMTP client. AI drafting can be added by piping the
/// copilot output into `body`.
struct ComposeView: View {
    @Environment(CourierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var fromAccountID: UUID?
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Message").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task { await send() }
                } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend || sending)
            }
            .padding(12)
            Divider()

            Form {
                Picker("From", selection: $fromAccountID) {
                    ForEach(store.accounts) { acc in Text(acc.emailAddress).tag(Optional(acc.id)) }
                }
                TextField("To", text: $to)
                TextField("Cc", text: $cc)
                TextField("Subject", text: $subject)
            }
            .formStyle(.grouped)

            TextEditor(text: $bodyText)
                .font(.body)
                .padding(8)
                .frame(minHeight: 220)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            if let draft = store.composeDraft {
                fromAccountID = draft.accountID
                to = draft.to; cc = draft.cc; subject = draft.subject; bodyText = draft.body
            } else if fromAccountID == nil {
                fromAccountID = store.accounts.first?.id
            }
        }
    }

    private var canSend: Bool {
        fromAccountID != nil && to.contains("@") && !subject.isEmpty
    }

    private func send() async {
        guard let account = store.accounts.first(where: { $0.id == fromAccountID }) else { return }
        sending = true; error = nil
        defer { sending = false }
        let message = OutgoingMessage(
            from: MailAddress(name: account.displayName, address: account.emailAddress),
            to: parseAddresses(to),
            cc: parseAddresses(cc),
            subject: subject,
            textBody: bodyText
        )
        if await store.send(message, from: account) {
            dismiss()
        } else {
            error = store.banner
        }
    }

    private func parseAddresses(_ raw: String) -> [MailAddress] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { MailAddress(address: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.address.contains("@") }
    }
}

import SwiftUI

/// Per-folder notification preferences.
///
/// Fastmail's server-side rules file mail into folders before the client ever
/// sees it, and JMAP carries no per-mailbox "notify me" flag, so the choice
/// lives here instead of on the server.
struct SettingsView: View {
    @ObservedObject var store: MailStore
    @AppStorage(NotifyingMailboxes.storageKey) private var notifyingList = ""

    var body: some View {
        Form {
            Section {
                if store.mailboxes.isEmpty {
                    Text("Connect an account to choose folders.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.mailboxes) { mailbox in
                        Toggle(isOn: binding(for: mailbox)) {
                            Label(mailbox.displayName, systemImage: mailbox.iconName)
                        }
                    }
                }
            } header: {
                Text("Notify me about new mail in")
            } footer: {
                Text("Server rules can file mail straight into a folder without it ever reaching the Inbox. Switch that folder on to be notified anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
    }

    private func binding(for mailbox: Mailbox) -> Binding<Bool> {
        Binding(
            get: { NotifyingMailboxes.ids(in: notifyingList).contains(mailbox.id) },
            set: { isOn in
                var ids = NotifyingMailboxes.ids(in: notifyingList)
                if isOn {
                    ids.insert(mailbox.id)
                } else {
                    ids.remove(mailbox.id)
                }

                notifyingList = NotifyingMailboxes.list(from: ids)
            }
        )
    }
}

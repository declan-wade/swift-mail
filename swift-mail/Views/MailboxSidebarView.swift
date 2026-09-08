import SwiftUI

struct MailboxSidebarView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        List(selection: $store.selectedMailboxID) {
            Section(store.account?.displayName ?? "Mail") {
                ForEach(store.mailboxes) { mailbox in
                    Label {
                        HStack {
                            Text(mailbox.displayName)
                            Spacer()
                            if let unread = mailbox.unreadEmails, unread > 0 {
                                Text(unread, format: .number)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: iconName(for: mailbox))
                    }
                    .tag(mailbox.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: Theme.Column.sidebar.min, ideal: Theme.Column.sidebar.ideal)
        .onChange(of: store.selectedMailboxID) { _, mailboxID in
            guard let mailboxID else {
                return
            }

            Task {
                await store.loadEmails(mailboxID: mailboxID)
            }
        }
    }

    private func iconName(for mailbox: Mailbox) -> String {
        switch mailbox.role {
        case "inbox":
            return "tray"
        case "sent":
            return "paperplane"
        case "drafts":
            return "doc"
        case "trash":
            return "trash"
        case "archive":
            return "archivebox"
        case "junk":
            return "exclamationmark.octagon"
        default:
            return "folder"
        }
    }
}

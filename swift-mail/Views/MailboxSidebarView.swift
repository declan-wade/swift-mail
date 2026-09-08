import SwiftUI

struct MailboxSidebarView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        List(selection: $store.selectedMailboxID) {
            Section(store.account?.displayName ?? "Mail") {
                ForEach(MailboxNode.tree(from: store.mailboxes)) { node in
                    OutlineGroup(node, children: \.children) { item in
                        MailboxRow(mailbox: item.mailbox)
                            .tag(item.mailbox.id)
                    }
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
}

/// One mailbox plus its sub-mailboxes, so the sidebar can show the folder
/// hierarchy the server reports through `parentId` instead of a flat list.
struct MailboxNode: Identifiable {
    let mailbox: Mailbox
    var children: [MailboxNode]?

    var id: String { mailbox.id }

    /// Rebuilds the parent/child hierarchy from a flat, already-sorted list.
    /// Mailboxes whose parent is missing from the list are treated as roots so
    /// nothing is dropped.
    static func tree(from mailboxes: [Mailbox]) -> [MailboxNode] {
        let known = Set(mailboxes.map(\.id))
        let childrenByParent = Dictionary(grouping: mailboxes) { $0.parentId ?? "" }

        func children(of parentID: String) -> [MailboxNode]? {
            guard let kids = childrenByParent[parentID], !kids.isEmpty else {
                return nil
            }

            return kids.map { MailboxNode(mailbox: $0, children: children(of: $0.id)) }
        }

        let roots = mailboxes.filter { mailbox in
            guard let parentID = mailbox.parentId else {
                return true
            }

            return !known.contains(parentID)
        }

        return roots.map { MailboxNode(mailbox: $0, children: children(of: $0.id)) }
    }
}

private struct MailboxRow: View {
    let mailbox: Mailbox

    var body: some View {
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
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
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

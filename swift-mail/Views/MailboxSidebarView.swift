import SwiftUI

struct MailboxSidebarView: View {
    @ObservedObject var store: MailStore
    /// Collapsed state sticks: someone who works out of the system mailboxes
    /// and keeps forty folders folded away shouldn't refold them every launch.
    @AppStorage("swift-mail.sidebar.foldersExpanded") private var foldersExpanded = true
    @AppStorage("swift-mail.sidebar.favouritesExpanded") private var favouritesExpanded = true
    @AppStorage(FavouriteMailboxes.storageKey) private var favouriteList = ""

    var body: some View {
        List(selection: $store.selectedMailboxID) {
            let roots = MailboxNode.tree(from: store.mailboxes)
            let favouriteIDs = FavouriteMailboxes.ids(in: favouriteList)
            // Filtered from the full list rather than from the roots, so a
            // nested folder can be favourited too.
            let favourites = store.mailboxes.filter { favouriteIDs.contains($0.id) }

            Section(store.account?.displayName ?? "Mail") {
                rows(for: roots.filter(\.mailbox.isSystem))
            }

            // Absent entirely when nothing is favourited: an empty section
            // header is a promise of content that isn't there.
            if !favourites.isEmpty {
                Section(isExpanded: $favouritesExpanded) {
                    // Flat, not a tree: a favourite is one mailbox someone
                    // picked, and dragging its children along would make
                    // favouriting a parent a different act from favouriting
                    // any other folder.
                    ForEach(favourites) { mailbox in
                        MailboxRow(mailbox: mailbox)
                            .tag(mailbox.id)
                    }
                } header: {
                    Text("Favourites")
                }
            }

            // Favourites and Folders collapse; the account's own mailboxes
            // don't. That's where mail is actually read, and a sidebar whose
            // Inbox can be hidden behind a triangle is one that will hide it.
            Section(isExpanded: $foldersExpanded) {
                rows(for: roots.filter { !$0.mailbox.isSystem })
            } header: {
                Text("Folders")
            }
        }
        .navigationSplitViewColumnWidth(min: Theme.Column.sidebar.min, ideal: Theme.Column.sidebar.ideal)
        .safeAreaInset(edge: .top) {
            // Absent entirely until the user makes a tag, which is what keeps
            // an untagged account looking exactly as it did.
            if !store.tags.isEmpty {
                TagFilterBar(store: store)
            }
        }
        .onChange(of: store.selectedMailboxID) { _, mailboxID in
            guard let mailboxID else {
                return
            }

            Task {
                await store.loadEmails(mailboxID: mailboxID)
            }
        }
    }

    @ViewBuilder
    private func rows(for nodes: [MailboxNode]) -> some View {
        ForEach(nodes) { node in
            OutlineGroup(node, children: \.children) { item in
                MailboxRow(mailbox: item.mailbox)
                    .tag(item.mailbox.id)
            }
        }
    }
}

/// The tag switcher, pinned above the folders: one chip per tag, plus All for
/// the unified view. Pinned rather than scrolled because it says what the
/// whole window is currently showing, which is not something to have to scroll
/// back up to check.
///
/// ponytail: the unread counts beside each folder stay the server's whole-folder
/// numbers while a tag is selected — per-tag counts would be a `Email/query`
/// per folder per sync. Add them if the mismatch starts misleading anyone.
private struct TagFilterBar: View {
    @ObservedObject var store: MailStore

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.xs) {
                chip(name: "All", color: .secondary, isOn: store.activeTagID == nil) {
                    store.activeTagID = nil
                }

                ForEach(store.tags) { tag in
                    chip(name: tag.displayName, color: tag.color.color, isOn: store.activeTagID == tag.id) {
                        // Clicking the tag you are already in is the way back
                        // out, so the chips can never strand you in one inbox.
                        store.activeTagID = store.activeTagID == tag.id ? nil : tag.id
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
        // `.never`, not `.hidden`: hidden is a preference the system overrides
        // when "Show scroll bars" is set to Always, which put a full-width bar
        // under the pills. The overflow is obvious from the chips themselves.
        .scrollIndicators(.never)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(name: String, color: Color, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isOn ? color : Color.secondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(color.opacity(isOn ? 0.2 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(isOn ? 0 : 0.25)))
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.hover, value: isOn)
        .help(isOn ? "Showing \(name)" : "Show \(name)")
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
    @AppStorage(FavouriteMailboxes.storageKey) private var favouriteList = ""

    private var isFavourite: Bool {
        FavouriteMailboxes.ids(in: favouriteList).contains(mailbox.id)
    }

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
            Image(systemName: mailbox.iconName)
        }
        // On the row itself, so the same menu is there whether the row is read
        // from Favourites, Folders or the account's own mailboxes.
        .contextMenu {
            Button(
                isFavourite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: isFavourite ? "star.slash" : "star"
            ) {
                favouriteList = FavouriteMailboxes.toggling(mailbox.id, in: favouriteList)
            }
        }
    }
}

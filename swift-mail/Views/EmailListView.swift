import AppKit
import SwiftUI

struct EmailListView: View {
    @ObservedObject var store: MailStore
    @Environment(\.openWindow) private var openWindow
    @State private var isSweeping = false

    private var searchBinding: Binding<String> {
        Binding(
            get: { store.searchText },
            set: { store.searchQueryChanged($0) }
        )
    }

    var body: some View {
        content
            .navigationTitle(store.selectedMailbox?.displayName ?? "Inbox")
            .navigationSplitViewColumnWidth(min: Theme.Column.list.min, ideal: Theme.Column.list.ideal)
            .toolbar { listToolbar }
            .sheet(isPresented: $isSweeping) {
                SweepView(store: store)
            }
            .searchable(text: searchBinding, prompt: "Search — try from: subject: after:")
            .searchSuggestions {
                ForEach(store.searchSuggestions) { suggestion in
                    HStack {
                        Text(suggestion.label)
                            .fontWeight(.medium)

                        if !suggestion.detail.isEmpty {
                            Text(suggestion.detail)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .searchCompletion(suggestion.completion)
                }
            }
            .onChange(of: store.selectedEmailID) { _, emailID in
                guard let emailID else {
                    return
                }

                Task {
                    await store.loadEmailDetail(emailID: emailID)
                }
            }
    }

    /// Whole-mailbox actions, as opposed to the per-message ones in the window
    /// toolbar. Declaring `.toolbar` on the content column does *not* place
    /// items above that column — a NavigationSplitView has one shared toolbar,
    /// and these just landed at its trailing end past the account menu.
    /// `.navigation` is what puts them at the leading edge, over the list.
    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                openWindow(id: ComposeWindow.id, value: ComposeDraft.blank(identity: store.defaultIdentity))
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .help("New Message (⌘N)")

            Button {
                isSweeping = true
            } label: {
                // SF Symbols has no broom; this is the closest "tidy in bulk"
                // metaphor and stays distinct from the pencil, arrows and
                // filter lines beside it.
                Label("Sweep", systemImage: "wand.and.sparkles")
            }
            .help("Sweep — bulk-move messages matching a search")
            .disabled(store.selectedMailboxID == nil)

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⇧⌘N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.isLoadingMailboxes || store.isLoadingEmails)

            Menu {
                ForEach(SearchQuery.QuickFilter.allCases) { filter in
                    Toggle(isOn: Binding(
                        get: { store.isActive(filter) },
                        set: { _ in store.toggle(filter) }
                    )) {
                        Label(filter.label, systemImage: filter.icon)
                    }
                }

                // Filters follow the user between folders, so the way out has
                // to be somewhere obvious rather than only the search field's
                // clear control.
                if !store.searchText.isEmpty {
                    Divider()

                    Button("Clear Search & Filters", systemImage: "xmark.circle") {
                        store.searchQueryChanged("")
                    }
                }
            } label: {
                Label(
                    "Filter",
                    systemImage: store.hasQuickFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
            .help("Filter Messages")
            .disabled(store.selectedMailboxID == nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoadingEmails && store.emails.isEmpty {
            SkeletonList()
        } else if let error = store.emailsErrorMessage, store.emails.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    guard let mailboxID = store.selectedMailboxID else {
                        return
                    }

                    Task { await store.loadEmails(mailboxID: mailboxID) }
                }
            }
        } else if store.emails.isEmpty {
            emptyState
        } else {
            messageList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            if let tag = store.activeTag {
                // An empty folder that is only empty because of the tag has to
                // say so and offer the way out, or it reads as lost mail.
                ContentUnavailableView {
                    Label("No \(tag.displayName) Mail", systemImage: "tray")
                } description: {
                    Text("Nothing in this folder was sent to or from \(tag.displayName)'s aliases.")
                } actions: {
                    Button("Show All Mail") { store.activeTagID = nil }
                }
            } else {
                ContentUnavailableView("No Messages", systemImage: "tray")
            }
        } else if store.isFilteredWithoutSearchTerms {
            // Quoting `is:unread` back at the user isn't an empty state.
            ContentUnavailableView(
                "No Matching Messages",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No messages in this folder match the active filter.")
            )
        } else {
            ContentUnavailableView.search(text: store.searchText)
        }
    }

    private var messageList: some View {
        List(selection: $store.selectedEmailID) {
            ForEach(store.emails) { email in
                EmailRow(email: email, store: store)
                    .tag(email.id)
                    .contextMenu {
                        Button(email.isUnread ? "Mark as Read" : "Mark as Unread") {
                            Task {
                                await store.toggleReadState(emailID: email.id)
                            }
                        }

                        Button(email.isFlagged ? "Unflag" : "Flag") {
                            Task {
                                await store.toggleFlag(emailID: email.id)
                            }
                        }

                        Divider()

                        Button("Archive") {
                            Task {
                                await store.archive(emailID: email.id)
                            }
                        }

                        Button("Delete", role: .destructive) {
                            Task {
                                await store.delete(emailID: email.id)
                            }
                        }
                    }
            }

            if store.hasMoreEmails {
                loadMoreRow
            }
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.sm)
        .listRowSeparator(.hidden)
        .onAppear {
            Task { await store.loadMoreEmails() }
        }
    }
}

private struct EmailRow: View {
    let email: EmailPreview
    @ObservedObject var store: MailStore
    @State private var isHovering = false
    @AppStorage(SwipePreferences.leadingKey) private var leading = SwipePreferences.leadingDefault.rawValue
    @AppStorage(SwipePreferences.trailingKey) private var trailing = SwipePreferences.trailingDefault.rawValue

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Circle()
                .fill(email.isUnread ? Color.accentColor : Color.clear)
                .frame(width: Theme.Size.unreadDot, height: Theme.Size.unreadDot)
                .padding(.top, 5)
                .accessibilityLabel(email.isUnread ? "Unread" : "Read")

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(email.senderLine)
                        .fontWeight(email.isUnread ? .semibold : .regular)
                        .lineLimit(1)

                    if email.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    if let tag {
                        Text(tag.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tag.color.color)
                            .lineLimit(1)
                            // The sender is the longer, more repetitive half of
                            // this row: it truncates before the label does.
                            .layoutPriority(1)
                    }

                    if isHovering {
                        quickActions
                    } else if let receivedAt = email.receivedAt {
                        Text(DateFormatter.mailShort.string(from: receivedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: Theme.Spacing.xs) {
                    Text(email.subjectLine)
                        .font(.callout)
                        .fontWeight(email.isUnread ? .semibold : .regular)
                        .lineLimit(1)

                    if email.hasAttachment == true {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Has attachment")
                    }
                }

                if let preview = email.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.sm - 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) {
                isHovering = hovering
            }
        }
        // Two-finger trackpad swipe, same as Mail: swiping all the way
        // across fires the action instead of just revealing the button.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            swipeButton(for: SwipeAction(rawValue: leading) ?? SwipePreferences.leadingDefault)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            swipeButton(for: SwipeAction(rawValue: trailing) ?? SwipePreferences.trailingDefault)
        }
    }

    /// The tag this message belongs to, or nil when there is nothing to say.
    /// Hidden while the window is narrowed to one tag, where every row would
    /// otherwise carry the same label.
    private var tag: MailTag? {
        guard store.activeTagID == nil else {
            return nil
        }

        return store.tags.tag(for: email)
    }

    @ViewBuilder
    private func swipeButton(for action: SwipeAction) -> some View {
        if action != .none {
            Button(role: action == .delete ? .destructive : nil) {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                Task { await action.perform(on: email, in: store) }
            } label: {
                Label(action.label(for: email), systemImage: action.icon(for: email))
            }
            .tint(action.tint)
        }
    }

    /// Row-hover quick actions, revealed in place of the timestamp — the
    /// same affordance Mail uses so the common actions don't require opening
    /// the message first.
    private var quickActions: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                Task { await store.toggleFlag(emailID: email.id) }
            } label: {
                Image(systemName: email.isFlagged ? "flag.fill" : "flag")
            }
            .foregroundStyle(.orange)

            Button {
                Task { await store.archive(emailID: email.id) }
            } label: {
                Image(systemName: "archivebox")
            }

            Button {
                Task { await store.delete(emailID: email.id) }
            } label: {
                Image(systemName: "trash")
            }
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .font(.callout)
    }
}

/// Placeholder rows shown while the first page of a mailbox loads, so the
/// column has structure instead of a lone spinner.
private struct SkeletonList: View {
    var body: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Sender Name Placeholder")
                        .fontWeight(.semibold)
                    Text("A representative subject line for layout")
                        .font(.callout)
                    Text("Two lines of preview text that stand in for the message body while it loads over the network.")
                        .font(.caption)
                        .lineLimit(2)
                }
                .padding(.vertical, Theme.Spacing.sm - 2)
                .redacted(reason: .placeholder)
            }
        }
        .disabled(true)
        .allowsHitTesting(false)
    }
}

import SwiftUI

struct EmailListView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Group {
            if store.isLoadingEmails && store.emails.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.emails.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "tray")
            } else {
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
                }
            }
        }
        .navigationTitle(store.selectedMailbox?.displayName ?? "Inbox")
        .navigationSplitViewColumnWidth(min: Theme.Column.list.min, ideal: Theme.Column.list.ideal)
        .onChange(of: store.selectedEmailID) { _, emailID in
            guard let emailID else {
                return
            }

            Task {
                await store.loadEmailDetail(emailID: emailID)
            }
        }
    }
}

private struct EmailRow: View {
    let email: EmailPreview
    @ObservedObject var store: MailStore
    @State private var isHovering = false

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

                    if isHovering {
                        quickActions
                    } else if let receivedAt = email.receivedAt {
                        Text(DateFormatter.mailShort.string(from: receivedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(email.subjectLine)
                    .font(.callout)
                    .fontWeight(email.isUnread ? .semibold : .regular)
                    .lineLimit(1)

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

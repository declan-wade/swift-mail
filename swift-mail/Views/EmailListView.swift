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
                        EmailRow(email: email)
                            .tag(email.id)
                            .contextMenu {
                                Button(email.isUnread ? "Mark as Read" : "Mark as Unread") {
                                    Task {
                                        await store.toggleReadState(emailID: email.id)
                                    }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle(store.selectedMailbox?.displayName ?? "Inbox")
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(email.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityLabel(email.isUnread ? "Unread" : "Read")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(email.senderLine)
                        .fontWeight(email.isUnread ? .semibold : .regular)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let receivedAt = email.receivedAt {
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
        .padding(.vertical, 6)
    }
}

import SwiftUI

struct EmailDetailView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Group {
            if store.isLoadingSelectedEmail && store.selectedEmail == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let email = store.selectedEmail {
                VStack(spacing: 0) {
                    ReaderHeader(email: email, store: store)

                    Divider()

                    HTMLMessageView(html: email.htmlDocument)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView("Select a Message", systemImage: "envelope.open")
            }
        }
        .navigationSplitViewColumnWidth(min: Theme.Column.detail.min, ideal: Theme.Column.detail.ideal)
    }
}

private struct ReaderHeader: View {
    let email: EmailDetail
    @ObservedObject var store: MailStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(email.subjectLine)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if email.isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Flagged")
                    }
                }

                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    SenderAvatar(name: email.from?.first?.name, email: email.from?.first?.email)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(email.senderLine)
                            .font(.headline)
                            .textSelection(.enabled)

                        if !email.recipientLine.isEmpty {
                            Text("To: \(email.recipientLine)")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }

                        if let receivedAt = email.receivedAt {
                            Text(DateFormatter.mailShort.string(from: receivedAt))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct SenderAvatar: View {
    let name: String?
    let email: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.16))

            Text(initials)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
        }
        .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let source = (name?.isEmpty == false ? name : email) ?? "?"
        let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

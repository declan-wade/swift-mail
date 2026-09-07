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
        .navigationSplitViewColumnWidth(min: 420, ideal: 680)
    }
}

private struct ReaderHeader: View {
    let email: EmailDetail
    @ObservedObject var store: MailStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(email.subjectLine)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 12) {
                    SenderAvatar(name: email.from?.first?.name, email: email.from?.first?.email)

                    VStack(alignment: .leading, spacing: 4) {
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
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 20)
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
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let source = (name?.isEmpty == false ? name : email) ?? "?"
        let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

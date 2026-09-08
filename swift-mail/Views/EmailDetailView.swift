import SwiftUI

struct EmailDetailView: View {
    @ObservedObject var store: MailStore
    /// Per-message: remote images stay blocked until the reader asks for them.
    @State private var loadsRemoteContent = false

    var body: some View {
        content
            .navigationSplitViewColumnWidth(min: Theme.Column.detail.min, ideal: Theme.Column.detail.ideal)
            .onChange(of: store.selectedEmailID) { _, _ in
                loadsRemoteContent = false
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoadingSelectedEmail && store.selectedEmail == nil {
            SkeletonReader()
        } else if let error = store.detailErrorMessage, store.selectedEmail == nil {
            ContentUnavailableView {
                Label("Couldn’t Load Message", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let emailID = store.selectedEmailID {
                    Button("Try Again") {
                        Task { await store.loadEmailDetail(emailID: emailID) }
                    }
                }
            }
        } else if store.selectedMailbox?.role == "drafts", let email = store.selectedEmail {
            DraftPlaceholder(email: email, store: store)
        } else if let email = store.selectedEmail {
            reader(for: email)
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope.open")
        }
    }

    private func reader(for email: EmailDetail) -> some View {
        VStack(spacing: 0) {
            ReaderHeader(
                email: email,
                store: store,
                showsRemoteContentNotice: email.htmlBodyLoadsRemoteContent && !loadsRemoteContent,
                onLoadRemoteContent: { loadsRemoteContent = true }
            )

            Divider()

            HTMLMessageView(html: email.htmlDocument, blocksRemoteContent: !loadsRemoteContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(email.id)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Drafts open for editing in a compose window rather than rendering in the
/// read-only reader. Selecting a draft opens (or refocuses) that window; the
/// button is here for when it has been closed.
private struct DraftPlaceholder: View {
    let email: EmailDetail
    @ObservedObject var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("Draft", systemImage: "square.and.pencil")
        } description: {
            Text(email.subjectLine)
        } actions: {
            Button("Edit Draft") { open() }
        }
        .task(id: email.id) { open() }
    }

    private func open() {
        openWindow(
            id: ComposeWindow.id,
            value: ComposeDraft.editDraft(from: email, identity: store.identity(id: nil))
        )
    }
}

private struct ReaderHeader: View {
    let email: EmailDetail
    @ObservedObject var store: MailStore
    var showsRemoteContentNotice = false
    var onLoadRemoteContent: () -> Void = {}

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

            if !email.listedAttachments.isEmpty {
                AttachmentList(attachments: email.listedAttachments)
            }

            if showsRemoteContentNotice {
                RemoteContentNotice(action: onLoadRemoteContent)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct RemoteContentNotice: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "photo.badge.arrow.down")
                .foregroundStyle(.secondary)

            // `fixedSize(vertical:)` without a line limit is what used to
            // wedge the whole window. Sharing a row with a `Spacer`, this text
            // is offered a near-zero width when SwiftUI computes the reader's
            // *minimum* height, and fixedSize then asks for however many lines
            // that takes — about 1180pt, which AppKit installed as the
            // window's `contentMinSize`. Taller than the screen, the window
            // could no longer shrink to the visible frame: filling it ran the
            // bottom under the Dock, dragging it out of a tiled state snapped
            // it back to the top edge, and the over-tall content overflowed
            // upward beneath the transparent titlebar, so the toolbar sat on
            // top of the reader and the first message row. The line limit
            // bounds that height while still letting the notice wrap, the same
            // way the subject line above does.
            Text("Remote images in this message weren’t loaded to protect your privacy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Spacing.sm)

            Button("Load Images", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.md)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }
}

private struct AttachmentList: View {
    let attachments: [EmailAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("\(attachments.count) Attachment\(attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "doc")
                        Text(attachment.displayName)
                            .lineLimit(1)
                        if let size = attachment.sizeDescription {
                            Text(size)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                }
            }
        }
    }
}

/// A minimal wrapping HStack — the attachment chips flow onto as many rows as
/// they need instead of overflowing the header.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                totalHeight += rowHeight + spacing
                rows.append([])
                x = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(subview)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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

/// Redacted stand-in for the reader while a message loads.
private struct SkeletonReader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("A representative message subject line")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Circle()
                    .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Sender Name")
                        .font(.headline)
                    Text("To: a couple of recipients")
                        .font(.callout)
                    Text("A moment ago")
                        .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    Text("Message body placeholder line that stands in for content while it loads.")
                        .font(.body)
                }
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .redacted(reason: .placeholder)
    }
}

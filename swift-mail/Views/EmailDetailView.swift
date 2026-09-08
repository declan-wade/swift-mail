import QuickLook
import SwiftUI

/// Sender domains whose messages always render remote content.
///
/// Stored as one comma-separated string so the whole feature is an
/// `@AppStorage` line rather than a store: matching is exact, so
/// "evil-fastmail.com" never rides in on "fastmail.com".
enum SafeSenders {
    static let storageKey = "swift-mail.safeSenderDomains"

    static func domain(of address: String?) -> String? {
        guard let domain = address?.split(separator: "@").last else {
            return nil
        }

        return domain.lowercased().nilIfEmpty
    }

    static func contains(_ domain: String, in list: String) -> Bool {
        domains(in: list).contains(domain.lowercased())
    }

    static func adding(_ domain: String, to list: String) -> String {
        domains(in: list).union([domain.lowercased()]).sorted().joined(separator: ",")
    }

    private static func domains(in list: String) -> Set<String> {
        Set(
            list.split(separator: ",")
                .compactMap { $0.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty }
        )
    }
}

struct EmailDetailView: View {
    @ObservedObject var store: MailStore
    /// Per-message: remote images stay blocked until the reader asks for them.
    @State private var loadsRemoteContent = false
    @AppStorage(SafeSenders.storageKey) private var safeSenderDomains = ""

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
        let domain = SafeSenders.domain(of: email.from?.first?.email)
        let loadsRemote = loadsRemoteContent
            || (domain.map { SafeSenders.contains($0, in: safeSenderDomains) } ?? false)

        return VStack(spacing: 0) {
            ReaderHeader(
                email: email,
                store: store,
                showsRemoteContentNotice: email.htmlBodyLoadsRemoteContent && !loadsRemote,
                onLoadRemoteContent: { loadsRemoteContent = true },
                senderDomain: domain,
                onTrustSenderDomain: { safeSenderDomains = SafeSenders.adding($0, to: safeSenderDomains) }
            )

            Divider()

            HTMLMessageView(html: email.htmlDocument, blocksRemoteContent: !loadsRemote)
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
    var senderDomain: String?
    var onTrustSenderDomain: (String) -> Void = { _ in }

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
                AttachmentList(attachments: email.listedAttachments, store: store)
            }

            if showsRemoteContentNotice {
                RemoteContentNotice(
                    action: onLoadRemoteContent,
                    senderDomain: senderDomain,
                    trustAction: onTrustSenderDomain
                )
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
    var senderDomain: String?
    var trustAction: (String) -> Void = { _ in }

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

            if let senderDomain {
                Button("Add \(senderDomain) to Safe Senders") { trustAction(senderDomain) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Always load remote content from \(senderDomain).")
            }

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
    @ObservedObject var store: MailStore
    /// Quick Look handles the file types itself — PDFs, images, text, Office
    /// documents — so there is no per-type preview code here.
    @State private var previewURL: URL?
    @State private var busyID: EmailAttachment.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("\(attachments.count) Attachment\(attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        isBusy: busyID == attachment.id,
                        onPreview: { run(attachment) { previewURL = try await store.previewFile(for: $0) } },
                        onSave: { run(attachment) { try await store.saveToDownloads($0) } }
                    )
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    /// Both actions download first, so they share the spinner and the alert.
    private func run(_ attachment: EmailAttachment, action: @escaping (EmailAttachment) async throws -> Void) {
        guard busyID == nil else {
            return
        }

        busyID = attachment.id
        Task {
            do {
                try await action(attachment)
            } catch {
                store.errorMessage = error.localizedDescription
            }

            busyID = nil
        }
    }
}

private struct AttachmentChip: View {
    let attachment: EmailAttachment
    let isBusy: Bool
    let onPreview: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button(action: onPreview) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "doc")
                    Text(attachment.displayName)
                        .lineLimit(1)
                    if let size = attachment.sizeDescription {
                        Text(size)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Quick Look \(attachment.displayName)")

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: onSave) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save to Downloads")
            }
        }
        .font(.callout)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .disabled(isBusy)
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

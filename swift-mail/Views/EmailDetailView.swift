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
    /// Per-message, like the remote-content block: a warning the reader has
    /// looked at and disagreed with shouldn't keep shouting, but it also
    /// shouldn't teach the app that the domain is fine — the next message
    /// claiming the same brand is a fresh question.
    @State private var dismissesSenderWarning = false
    @AppStorage(SafeSenders.storageKey) private var safeSenderDomains = ""

    var body: some View {
        content
            .navigationSplitViewColumnWidth(min: Theme.Column.detail.min, ideal: Theme.Column.detail.ideal)
            .onChange(of: store.selectedEmailID) { _, _ in
                loadsRemoteContent = false
                dismissesSenderWarning = false
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
        } else if let email = store.selectedEmail, email.isDraft {
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
        // Safe Senders deliberately doesn't silence this. Trusting a domain
        // with remote images is a statement about tracking pixels, not about
        // whether the sender is who the name says.
        let impersonated = dismissesSenderWarning
            ? nil
            : SenderImpersonation.impersonatedBrand(
                displayName: email.from?.first?.name,
                address: email.from?.first?.email
            )

        return VStack(spacing: 0) {
            if store.conversation.count > 1 {
                ConversationStrip(store: store, selectedID: email.id)
                Divider()
            }

            ReaderHeader(
                email: email,
                store: store,
                showsRemoteContentNotice: email.htmlBodyLoadsRemoteContent && !loadsRemote,
                onLoadRemoteContent: { loadsRemoteContent = true },
                senderDomain: domain,
                onTrustSenderDomain: { safeSenderDomains = SafeSenders.adding($0, to: safeSenderDomains) },
                impersonatedBrand: impersonated,
                onReportPhishing: {
                    Task { await store.reportSpam(emailID: email.id, isPhishing: true) }
                },
                onDismissSenderWarning: { dismissesSenderWarning = true }
            )

            Divider()

            HTMLMessageView(
                html: email.htmlDocument,
                inlineImageResolver: { cid in await store.inlineImage(cid: cid, in: email) },
                blocksRemoteContent: !loadsRemote
            )
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

/// Every message in the open conversation, oldest first, with the one being
/// read marked. Clicking a row moves the reader to that message.
///
/// A strip rather than the stacked, all-expanded layout Mimestream uses:
/// stacking needs each message's rendered height, and the only way to get that
/// out of a `WKWebView` is to run JavaScript in it — which this app disables on
/// purpose for mail it did not author.
private struct ConversationStrip: View {
    @ObservedObject var store: MailStore
    let selectedID: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(store.conversation.enumerated()), id: \.element.id) { index, message in
                        Button {
                            guard message.id != selectedID else { return }
                            Task { await store.loadEmailDetail(emailID: message.id) }
                        } label: {
                            row(for: message, position: index + 1)
                        }
                        .buttonStyle(.plain)
                        .id(message.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedID, initial: true) { _, id in
                withAnimation(Theme.Motion.hover) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(for message: EmailPreview, position: Int) -> some View {
        let isSelected = message.id == selectedID

        return HStack(spacing: Theme.Spacing.xs) {
            Text("\(position)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            if message.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: Theme.Size.unreadDot, height: Theme.Size.unreadDot)
            }

            Text(message.senderLine)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)

            if let receivedAt = message.receivedAt {
                Text(DateFormatter.mailShort.string(from: receivedAt))
                    .foregroundStyle(.secondary)
            }

            if message.hasAttachment == true {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary), in: Capsule())
        .help(message.subjectLine)
    }
}

private struct ReaderHeader: View {
    let email: EmailDetail
    @ObservedObject var store: MailStore
    var showsRemoteContentNotice = false
    var onLoadRemoteContent: () -> Void = {}
    var senderDomain: String?
    var onTrustSenderDomain: (String) -> Void = { _ in }
    var impersonatedBrand: SenderImpersonation.Brand?
    var onReportPhishing: () -> Void = {}
    var onDismissSenderWarning: () -> Void = {}

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

            if let impersonatedBrand, let senderDomain {
                SenderMismatchNotice(
                    brand: impersonatedBrand,
                    senderDomain: senderDomain,
                    onReport: onReportPhishing,
                    onDismiss: onDismissSenderWarning
                )
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

/// States the mismatch and stops.
///
/// It names both halves — the brand the message claims and the domain it came
/// from — because that sentence is checkable, where "this looks like phishing"
/// is something the reader can only take on faith. The buttons are the two
/// honest answers to it; nothing here moves the message on its own.
private struct SenderMismatchNotice: View {
    let brand: SenderImpersonation.Brand
    let senderDomain: String
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)

            // Same shape as the remote-content notice below, for the same
            // reason: a line limit bounds the height that `fixedSize` would
            // otherwise ask for next to a `Spacer`.
            Text("This message says it’s from \(brand.name), but it was sent from \(senderDomain).")
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Spacing.sm)

            Button("Not Phishing", action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Hide this warning for this message.")

            Button("Report Phishing", action: onReport)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .help("Mark as phishing and move to Spam.")
        }
        .padding(Theme.Spacing.md)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(.orange.opacity(0.35))
        )
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
    /// The attachment showing its "saved" tick, and the timer that clears it.
    @State private var savedID: EmailAttachment.ID?
    @State private var savedResetTask: Task<Void, Never>?
    @AppStorage(DownloadPreferences.bookmarkKey) private var downloadBookmark: Data?

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
                        hasSaved: savedID == attachment.id,
                        destinationName: DownloadPreferences.folderName(from: downloadBookmark),
                        onPreview: { run(attachment) { previewURL = try await store.previewFile(for: $0) } },
                        onSave: {
                            run(attachment) {
                                try await store.saveAttachment($0)
                                markSaved($0.id)
                            }
                        }
                    )
                }
            }
        }
        .quickLookPreview($previewURL)
        .onDisappear { savedResetTask?.cancel() }
    }

    /// The tick is the only confirmation a save gets — no alert, no Finder
    /// window — so it stays long enough to be read and then gets out of the way
    /// rather than becoming permanent chrome on the chip.
    private func markSaved(_ id: EmailAttachment.ID) {
        savedID = id
        savedResetTask?.cancel()
        savedResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }

            savedID = nil
        }
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

/// Two targets in one chip: the name previews, the trailing segment saves.
///
/// The save used to be a bare glyph sitting in the chip's own padding, so its
/// hit area was the size of the arrow itself. Here the chip carries no padding
/// of its own — each half pads itself instead — which turns the padding into
/// target for whichever half it belongs to, and a divider makes the boundary
/// something you can aim at rather than guess.
private struct AttachmentChip: View {
    let attachment: EmailAttachment
    let isBusy: Bool
    let hasSaved: Bool
    let destinationName: String
    let onPreview: () -> Void
    let onSave: () -> Void

    @State private var isHoveringSave = false

    var body: some View {
        HStack(spacing: 0) {
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
                .padding(.leading, Theme.Spacing.sm)
                .padding(.trailing, Theme.Spacing.xs)
                .padding(.vertical, Theme.Spacing.xs)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Quick Look \(attachment.displayName)")

            Divider()
                .frame(height: Self.saveTarget * 0.55)

            Button(action: onSave) {
                saveIcon
                    .frame(width: Self.saveTarget, height: Self.saveTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasSaved ? Color.green : Color.secondary)
            .background(
                isHoveringSave ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small)
            )
            .help(hasSaved ? "Saved to \(destinationName)" : "Save to \(destinationName)")
            .onHover { hovering in
                withAnimation(Theme.Motion.hover) {
                    isHoveringSave = hovering
                }
            }
        }
        .font(.callout)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .disabled(isBusy)
    }

    /// Square, and wide enough to hit without aiming. The arrow is drawn a step
    /// larger than the chip's text so the target reads as a control rather than
    /// as punctuation after the filename.
    private static let saveTarget: CGFloat = 26

    @ViewBuilder
    private var saveIcon: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: hasSaved ? "checkmark.circle.fill" : "arrow.down.circle")
                .imageScale(.large)
                .contentTransition(.symbolEffect(.replace))
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

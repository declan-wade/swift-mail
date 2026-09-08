import CryptoKit
import Foundation

/// A sending identity, as returned by `Identity/get` (RFC 8621 §6).
nonisolated struct MailIdentity: Identifiable, Hashable, Codable {
    let id: String
    let name: String?
    let email: String
    let replyTo: [EmailAddress]?
    let bcc: [EmailAddress]?
    let textSignature: String?
    let htmlSignature: String?

    var address: EmailAddress {
        EmailAddress(name: name, email: email)
    }

    var displayName: String {
        guard let name = name?.nilIfEmpty else {
            return email
        }

        return "\(name) <\(email)>"
    }
}

/// Why a draft was opened. Reply and forward differ only in how the draft is
/// seeded and in which keyword the original message picks up once it is sent.
nonisolated enum ComposeMode: String, Codable, Hashable {
    case new
    case reply
    case replyAll
    case forward
    /// Resuming a message already saved in the Drafts mailbox.
    case editDraft

    /// The keyword set on the message this draft responds to, once it is sent.
    var originalKeyword: String? {
        switch self {
        case .new, .editDraft: return nil
        case .reply, .replyAll: return "$answered"
        case .forward: return "$forwarded"
        }
    }
}

/// A file already uploaded to the server and ready to be referenced by blob id
/// when the message is created.
///
/// Only uploaded files get this far: an attachment that failed to upload is
/// reported and dropped rather than sitting in the draft in a broken state, so
/// there is no "pending" case to reason about at send time.
nonisolated struct ComposeAttachment: Identifiable, Hashable, Codable {
    let blobId: String
    let name: String
    let type: String
    let size: Int

    var id: String { blobId }

    var sizeDescription: String {
        Int64(size).formatted(.byteCount(style: .file))
    }
}

/// Everything a compose window needs to restore itself.
///
/// This is the value carried by the compose `WindowGroup`, so it has to stay
/// `Codable` and `Hashable`: SwiftUI persists it for state restoration and uses
/// its identity to decide whether to open a new window or focus an existing one.
/// The per-draft `id` is what keeps two replies to the same message apart.
nonisolated struct ComposeDraft: Identifiable, Hashable, Codable {
    var id = UUID()
    var mode: ComposeMode = .new
    var identityID: String?
    var to: [EmailAddress] = []
    var cc: [EmailAddress] = []
    var bcc: [EmailAddress] = []
    var subject = ""
    /// The body, authored as Markdown. Sent verbatim as the `text/plain` part.
    var markdown = ""
    /// Threading headers carried over from the message being answered.
    var inReplyTo: [String] = []
    var references: [String] = []
    /// The message this draft answers, so it can be flagged once the draft sends.
    var originalEmailID: String?
    /// When resuming a saved draft, the Drafts-mailbox email this window came
    /// from — destroyed once the resumed draft is re-saved or sent so its stale
    /// earlier version doesn't linger.
    var sourceDraftID: String?
    /// Persisted so a reopened window keeps the fields the user revealed.
    var showsCarbonCopy = false
    var attachments: [ComposeAttachment] = []

    var hasRecipients: Bool {
        !(to.isEmpty && cc.isEmpty && bcc.isEmpty)
    }

    var allRecipients: [EmailAddress] {
        to + cc + bcc
    }

    var windowTitle: String {
        subject.nilIfEmpty ?? "New Message"
    }

    /// Whether anything the user would mind losing differs from `original`.
    ///
    /// `identityID` is deliberately excluded: the compose window fills it in
    /// from the default identity just after opening, and treating that as an
    /// edit would prompt on closing a window nobody typed in. `id`, `mode` and
    /// the threading headers are seeded, never edited.
    func hasChanges(from original: ComposeDraft) -> Bool {
        to != original.to
            || cc != original.cc
            || bcc != original.bcc
            || subject != original.subject
            || markdown != original.markdown
            || attachments != original.attachments
    }
}

// MARK: - Seeding drafts

nonisolated extension ComposeDraft {
    static func blank(identity: MailIdentity?) -> ComposeDraft {
        ComposeDraft(
            identityID: identity?.id,
            bcc: identity?.bcc ?? [],
            markdown: signatureBlock(for: identity)
        )
    }

    /// Resumes a message from the Drafts mailbox. The window id is derived from
    /// the source email so re-selecting the same draft focuses the open window
    /// instead of spawning a second one.
    static func editDraft(from email: EmailDetail, identity: MailIdentity?) -> ComposeDraft {
        let carbonCopy = email.cc ?? []
        let blindCarbonCopy = email.bcc ?? []

        var draft = ComposeDraft(
            id: deterministicID(for: "draft:\(email.id)"),
            mode: .editDraft,
            identityID: identity?.id,
            to: email.to ?? [],
            cc: carbonCopy,
            bcc: blindCarbonCopy,
            subject: email.subject ?? "",
            markdown: email.readableBody,
            inReplyTo: email.inReplyTo ?? [],
            references: email.references ?? [],
            showsCarbonCopy: !carbonCopy.isEmpty || !blindCarbonCopy.isEmpty
        )

        draft.sourceDraftID = email.id
        // The blobs are already on the server, so a resumed draft keeps its
        // attachments without re-uploading anything.
        draft.attachments = email.listedAttachments.compactMap { attachment in
            guard let blobId = attachment.blobId else {
                return nil
            }

            return ComposeAttachment(
                blobId: blobId,
                name: attachment.displayName,
                type: attachment.type ?? "application/octet-stream",
                size: attachment.size ?? 0
            )
        }

        return draft
    }

    /// A stable UUID for a given seed string, so a window value stays equal
    /// across reopens and SwiftUI reuses the existing window.
    private static func deterministicID(for seed: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(seed.utf8))
        return NSUUID(uuidBytes: Array(digest)) as UUID
    }

    static func reply(to email: EmailDetail, identity: MailIdentity?, replyAll: Bool) -> ComposeDraft {
        // Reply-To wins over From when the sender asked for replies elsewhere.
        let primary = email.replyTo?.nilIfEmpty ?? email.from ?? []
        let selfAddresses = Set([identity?.email.lowercased()].compactMap { $0 })

        var carbonCopy: [EmailAddress] = []
        if replyAll {
            carbonCopy = ((email.to ?? []) + (email.cc ?? []))
                .filter { !selfAddresses.contains($0.email.lowercased()) }
                .removingDuplicates(against: primary)
        }

        var draft = ComposeDraft(
            mode: replyAll ? .replyAll : .reply,
            identityID: identity?.id,
            to: primary.removingDuplicates(),
            cc: carbonCopy,
            bcc: identity?.bcc ?? [],
            subject: email.subjectLine.prefixed(with: "Re:"),
            markdown: signatureBlock(for: identity) + quotedReply(to: email),
            originalEmailID: email.id,
            showsCarbonCopy: !carbonCopy.isEmpty
        )

        draft.applyThreading(from: email)
        return draft
    }

    static func forward(_ email: EmailDetail, identity: MailIdentity?) -> ComposeDraft {
        var draft = ComposeDraft(
            mode: .forward,
            identityID: identity?.id,
            bcc: identity?.bcc ?? [],
            subject: email.subjectLine.prefixed(with: "Fwd:"),
            markdown: signatureBlock(for: identity) + forwardedBody(of: email),
            originalEmailID: email.id
        )

        draft.applyThreading(from: email)
        return draft
    }

    private mutating func applyThreading(from email: EmailDetail) {
        guard let messageID = email.messageId?.first else {
            return
        }

        inReplyTo = [messageID]
        // References accumulates the whole ancestry so threading survives clients
        // that only look at this header.
        references = (email.references ?? email.inReplyTo ?? []) + [messageID]
    }

    /// Leading blank lines put the cursor above the signature and quoted text,
    /// which is where the reply actually gets written.
    private static func signatureBlock(for identity: MailIdentity?) -> String {
        guard let signature = identity?.textSignature?.nilIfEmpty else {
            return ""
        }

        return "\n\n\(signature)"
    }

    private static func quotedReply(to email: EmailDetail) -> String {
        let attribution: String
        if let date = email.receivedAt ?? email.sentAt {
            attribution = "On \(DateFormatter.mailAttribution.string(from: date)), \(email.senderLine) wrote:"
        } else {
            attribution = "\(email.senderLine) wrote:"
        }

        return "\n\n\(attribution)\n\n\(email.readableBody.markdownQuoted())"
    }

    private static func forwardedBody(of email: EmailDetail) -> String {
        var header = ["**---------- Forwarded message ----------**"]
        header.append("**From:** \(email.senderLine)")

        if let date = email.receivedAt ?? email.sentAt {
            header.append("**Date:** \(DateFormatter.mailAttribution.string(from: date))")
        }

        header.append("**Subject:** \(email.subjectLine)")

        if !email.recipientLine.isEmpty {
            header.append("**To:** \(email.recipientLine)")
        }

        // Hard breaks keep the header block on separate lines once rendered.
        let block = header.joined(separator: "  \n")
        return "\n\n\(block)\n\n\(email.readableBody)"
    }
}

// MARK: - Address parsing

nonisolated extension EmailAddress {
    /// Parses a recipient list of the form `Name <a@b.com>, c@d.com`.
    ///
    /// Splitting is done by hand rather than with a separator so a comma inside a
    /// quoted display name — `"Doe, Jane" <jane@x.com>` — does not split the entry.
    static func parseList(_ text: String) -> [EmailAddress] {
        var entries: [String] = []
        var current = ""
        var isQuoted = false
        var angleDepth = 0

        for character in text {
            switch character {
            case "\"":
                isQuoted.toggle()
                current.append(character)
            case "<" where !isQuoted:
                angleDepth += 1
                current.append(character)
            case ">" where !isQuoted:
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            case ",", ";", "\n":
                if isQuoted || angleDepth > 0 {
                    current.append(character)
                } else {
                    entries.append(current)
                    current = ""
                }
            default:
                current.append(character)
            }
        }

        entries.append(current)

        return entries.compactMap(EmailAddress.init(entry:))
    }

    /// Parses a single `Name <a@b.com>` or bare-address entry.
    init?(entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") else {
            let address = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard address.looksLikeEmailAddress else {
                return nil
            }

            self.init(email: address)
            return
        }

        let address = String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        guard address.looksLikeEmailAddress else {
            return nil
        }

        let name = String(trimmed[trimmed.startIndex..<open])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        self.init(name: name.nilIfEmpty, email: address)
    }

    /// Round-trips through `parseList`, so it is what the token field displays.
    var editableText: String {
        guard let name = name?.nilIfEmpty else {
            return email
        }

        let needsQuoting = name.contains(",") || name.contains(";") || name.contains("<")
        return needsQuoting ? "\"\(name)\" <\(email)>" : "\(name) <\(email)>"
    }

    static func editableText(for addresses: [EmailAddress]) -> String {
        addresses.map(\.editableText).joined(separator: ", ")
    }
}

// MARK: - Helpers

nonisolated extension DateFormatter {
    /// The date shown in a reply's attribution line.
    static let mailAttribution: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}

nonisolated private extension Array where Element == EmailAddress {
    var nilIfEmpty: [EmailAddress]? {
        isEmpty ? nil : self
    }

    func removingDuplicates() -> [EmailAddress] {
        removingDuplicates(against: [])
    }

    /// Deduplicates by address, ignoring display name, and drops anything already
    /// present in `existing` so a reply-all never addresses someone twice.
    func removingDuplicates(against existing: [EmailAddress]) -> [EmailAddress] {
        var seen = Set(existing.map { $0.email.lowercased() })

        return filter { address in
            seen.insert(address.email.lowercased()).inserted
        }
    }
}

nonisolated private extension String {
    var looksLikeEmailAddress: Bool {
        guard let at = firstIndex(of: "@"), at != startIndex else {
            return false
        }

        let domain = self[index(after: at)...]
        return !domain.isEmpty
            && domain.contains(".")
            && !domain.hasPrefix(".")
            && !domain.hasSuffix(".")
            && !contains(where: \.isWhitespace)
    }

    /// Adds `Re:`/`Fwd:` unless the subject already carries it.
    func prefixed(with prefix: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        guard !trimmed.lowercased().hasPrefix(prefix.lowercased()) else {
            return trimmed
        }

        return "\(prefix) \(trimmed)"
    }

    /// Turns the original message into a Markdown blockquote, which is exactly
    /// what a plain-text reply looks like — and renders as `<blockquote>`.
    func markdownQuoted() -> String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }
}

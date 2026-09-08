import Foundation
import AppKit

nonisolated struct MailAccount: Codable, Equatable {
    var displayName: String
    var sessionURL: URL
}

nonisolated struct JMAPSession: Decodable {
    let apiURL: URL
    let eventSourceURL: URL?
    /// Kept as the raw string: RFC 8620 6.2 defines it as a URI template, and
    /// `URL` percent-encodes the `{}` placeholders on decode.
    let downloadURLTemplate: String?
    let primaryAccounts: [String: String]
    /// Optional so a server that omits it still logs in; RFC 8620 2 requires it.
    let capabilities: [String: JMAPCapabilityProperties]?

    /// Expands `downloadUrl` for one blob. Every value is percent-encoded, so
    /// an attachment named `../../etc` can only ever be one path segment.
    func downloadURL(accountID: String, blobID: String, type: String?, name: String?) -> URL? {
        guard let downloadURLTemplate else {
            return nil
        }

        let values = [
            "accountId": accountID,
            "blobId": blobID,
            "type": type ?? "application/octet-stream",
            "name": name ?? "attachment"
        ]

        let expanded = values.reduce(downloadURLTemplate) { url, entry in
            let encoded = entry.value.addingPercentEncoding(withAllowedCharacters: .jmapTemplateValue) ?? ""

            return url
                .replacingOccurrences(of: "{\(entry.key)}", with: encoded)
                .replacingOccurrences(of: "%7B\(entry.key)%7D", with: encoded)
                .replacingOccurrences(of: "%7b\(entry.key)%7d", with: encoded)
        }

        return URL(string: expanded)
    }

    /// The extensions this server advertises. Only the URNs matter to us — a
    /// capability's own settings object is read where that feature is used.
    var capabilityURNs: Set<String> {
        Set((capabilities ?? [:]).keys)
    }

    func supports(_ capability: String) -> Bool {
        capabilityURNs.contains(capability)
    }

    var mailAccountID: String? {
        primaryAccounts["urn:ietf:params:jmap:mail"]
    }

    /// Submission usually lives on the same account as mail, but the spec allows
    /// them to differ, so prefer the advertised one and fall back to mail.
    var submissionAccountID: String? {
        primaryAccounts["urn:ietf:params:jmap:submission"] ?? mailAccountID
    }

    func eventSourceURL(types: [String], closeAfter: Int = 300) -> URL? {
        guard let eventSourceURL else {
            return nil
        }

        let typeList = types.joined(separator: ",")
        let absoluteString = eventSourceURL.absoluteString

        // RFC 8620 §7.3 defines `eventSourceUrl` as a URI template —
        // `.../{types}/{closeafter}/{ping}` — which is the form every
        // spec-compliant JMAP server actually sends. But `URL(string:)`
        // percent-encodes `{`/`}` the moment this struct is decoded from the
        // server's JSON, so by the time `absoluteString` is read here the
        // placeholders are already `%7Btypes%7D` etc., not the literal braces
        // — checking only the literal form would silently never match a real
        // server's URL and fall through to appending query items below,
        // which most servers don't recognize. `{ping}`, if present, is
        // substituted with `0` (no keepalive ping), since this client
        // doesn't need one.
        let hasTemplate = absoluteString.contains("{types}") || absoluteString.contains("%7Btypes%7D")
        if hasTemplate {
            let expanded = absoluteString
                .replacingOccurrences(of: "{types}", with: typeList)
                .replacingOccurrences(of: "%7Btypes%7D", with: typeList)
                .replacingOccurrences(of: "{closeafter}", with: String(closeAfter))
                .replacingOccurrences(of: "%7Bcloseafter%7D", with: String(closeAfter))
                .replacingOccurrences(of: "{ping}", with: "0")
                .replacingOccurrences(of: "%7Bping%7D", with: "0")

            return URL(string: expanded)
        }

        guard var components = URLComponents(url: eventSourceURL, resolvingAgainstBaseURL: false) else {
            return eventSourceURL
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "types" }) {
            queryItems.append(URLQueryItem(name: "types", value: typeList))
        }
        if !queryItems.contains(where: { $0.name == "closeafter" }) {
            queryItems.append(URLQueryItem(name: "closeafter", value: String(closeAfter)))
        }
        components.queryItems = queryItems

        return components.url
    }

    private enum CodingKeys: String, CodingKey {
        case apiURL = "apiUrl"
        case eventSourceURL = "eventSourceUrl"
        case downloadURLTemplate = "downloadUrl"
        case primaryAccounts
        case capabilities
    }
}

/// A capability's settings object, which this client doesn't inspect. Decoding
/// ignores the value entirely so an unfamiliar shape can never fail the session
/// decode and lock the user out of an otherwise working account.
nonisolated struct JMAPCapabilityProperties: Decodable {
    init(from decoder: Decoder) {}
}

private extension CharacterSet {
    /// Unreserved characters only (RFC 3986), so an expanded value can never
    /// introduce a `/`, `?` or `#` and change the URL's shape.
    static let jmapTemplateValue = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

nonisolated struct Mailbox: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let role: String?
    let parentId: String?
    let sortOrder: Int?
    let totalEmails: Int?
    let unreadEmails: Int?

    var displayName: String {
        if role == "inbox" {
            return "Inbox"
        }

        return name
    }

    /// Mailboxes the server manages itself, which the sidebar groups above the
    /// user's own folders.
    var isSystem: Bool { icon != nil }

    var iconName: String { icon ?? "folder" }

    /// Matched on role first, then on name: JMAP has no role for Fastmail's
    /// Snoozed, Scheduled or Memos mailboxes.
    /// ponytail: name matching also claims a user folder called e.g. "Notes";
    /// switch to a server-provided role if one ever appears.
    private var icon: String? {
        Self.systemIcons[role ?? ""] ?? Self.systemIcons[name.lowercased()]
    }

    private static let systemIcons: [String: String] = [
        "inbox": "tray",
        "snoozed": "moon.zzz",
        "archive": "archivebox",
        "memos": "note.text",
        "notes": "note.text",
        "drafts": "doc",
        "scheduled": "calendar.badge.clock",
        "sent": "paperplane",
        "junk": "exclamationmark.octagon",
        "spam": "exclamationmark.octagon",
        "trash": "trash",
        "templates": "doc.on.doc"
    ]
}

nonisolated struct EmailAddress: Hashable, Codable {
    let name: String?
    let email: String

    init(name: String? = nil, email: String) {
        self.name = name?.nilIfEmpty
        self.email = email
    }

    var displayName: String {
        guard let name, !name.isEmpty else {
            return email
        }

        return "\(name) <\(email)>"
    }
}

nonisolated struct EmailPreview: Identifiable, Hashable, Decodable {
    let id: String
    let threadId: String?
    let mailboxIds: [String: Bool]?
    let from: [EmailAddress]?
    let to: [EmailAddress]?
    let subject: String?
    let receivedAt: Date?
    let preview: String?
    let keywords: [String: Bool]?
    let hasAttachment: Bool?

    var senderLine: String {
        from?.first?.name?.nilIfEmpty ?? from?.first?.email ?? "Unknown Sender"
    }

    var subjectLine: String {
        subject?.nilIfEmpty ?? "No Subject"
    }

    var isUnread: Bool {
        keywords?["$seen"] != true
    }

    var isFlagged: Bool {
        keywords?["$flagged"] == true
    }

    /// Whether a newly arrived message warrants a notification: unread, filed in
    /// the Inbox, and recent. The recency guard keeps a reconnect after a long
    /// offline stretch — where `Email/changes` can report a backlog of older
    /// messages as "created" — from firing a burst of stale notifications.
    func warrantsNotification(mailboxID: String, now: Date = Date(), maxAge: TimeInterval = 3600) -> Bool {
        guard isUnread, mailboxIds?[mailboxID] == true else {
            return false
        }

        guard let receivedAt else {
            return true
        }

        return now.timeIntervalSince(receivedAt) <= maxAge
    }

    func settingSeen(_ isSeen: Bool) -> EmailPreview {
        settingKeyword("$seen", isSeen)
    }

    func settingFlagged(_ isFlagged: Bool) -> EmailPreview {
        settingKeyword("$flagged", isFlagged)
    }

    private func settingKeyword(_ keyword: String, _ isSet: Bool) -> EmailPreview {
        var keywords = keywords ?? [:]
        if isSet {
            keywords[keyword] = true
        } else {
            keywords.removeValue(forKey: keyword)
        }

        return EmailPreview(
            id: id,
            threadId: threadId,
            mailboxIds: mailboxIds,
            from: from,
            to: to,
            subject: subject,
            receivedAt: receivedAt,
            preview: preview,
            keywords: keywords,
            hasAttachment: hasAttachment
        )
    }
}

nonisolated struct EmailBodyPart: Hashable, Decodable {
    let partId: String?
    let type: String?
    let name: String?
}

/// A file attached to a message, as returned in `Email.attachments` (RFC 8621 §4.1.4).
nonisolated struct EmailAttachment: Hashable, Decodable, Identifiable {
    let blobId: String?
    let type: String?
    let name: String?
    let size: Int?
    let disposition: String?
    let cid: String?

    var id: String { blobId ?? "\(name ?? "attachment")-\(size ?? 0)" }

    /// Inline images referenced from the body by `cid:` are part of the message,
    /// not attachments the reader should list separately. A part explicitly
    /// marked `attachment` is always listed even when it carries a `cid`.
    var isInline: Bool {
        switch disposition?.lowercased() {
        case "inline":
            return true
        case "attachment":
            return false
        default:
            return cid != nil
        }
    }

    var displayName: String {
        name?.nilIfEmpty ?? "Attachment"
    }

    var sizeDescription: String? {
        guard let size, size > 0 else {
            return nil
        }

        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

nonisolated struct EmailDetail: Identifiable, Hashable, Decodable {
    let id: String
    let from: [EmailAddress]?
    let to: [EmailAddress]?
    let cc: [EmailAddress]?
    let bcc: [EmailAddress]?
    let replyTo: [EmailAddress]?
    let subject: String?
    let receivedAt: Date?
    let sentAt: Date?
    let messageId: [String]?
    let inReplyTo: [String]?
    let references: [String]?
    let preview: String?
    let keywords: [String: Bool]?
    let textBody: [EmailBodyPart]?
    let htmlBody: [EmailBodyPart]?
    let bodyValues: [String: EmailBodyValue]?
    let attachments: [EmailAttachment]?

    /// Attachments worth listing in the reader — inline images referenced by the
    /// HTML body are excluded.
    var listedAttachments: [EmailAttachment] {
        (attachments ?? []).filter { !$0.isInline }
    }

    var subjectLine: String {
        subject?.nilIfEmpty ?? "No Subject"
    }

    var senderLine: String {
        from?.first?.displayName ?? "Unknown Sender"
    }

    var recipientLine: String {
        to?.map(\.displayName).joined(separator: ", ") ?? ""
    }

    var isUnread: Bool {
        keywords?["$seen"] != true
    }

    var isFlagged: Bool {
        keywords?["$flagged"] == true
    }

    var readableBody: String {
        if let text = firstBodyValue(from: textBody) {
            return text
        }

        if let html = firstBodyValue(from: htmlBody) {
            return html.htmlStripped()
        }

        return preview ?? ""
    }

    /// Whether the HTML body pulls in resources over the network. Used to decide
    /// whether to offer a "Load Images" affordance before rendering.
    var htmlBodyLoadsRemoteContent: Bool {
        guard let html = firstBodyValue(from: htmlBody) else {
            return false
        }

        return html.range(
            of: "(src|background|srcset)\\s*=\\s*[\"']?\\s*https?://|url\\(\\s*[\"']?https?://",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    var htmlDocument: String {
        if let html = firstBodyValue(from: htmlBody) {
            return html.htmlEntityDecoded()
        }

        return """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    color: -apple-system-label;
                    font: -apple-system-body;
                    line-height: 1.5;
                    margin: 0;
                    overflow-wrap: anywhere;
                    padding: 0;
                }

                pre {
                    font: -apple-system-body;
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body><pre>\(readableBody.htmlEscaped())</pre></body>
        </html>
        """
    }

    func settingSeen(_ isSeen: Bool) -> EmailDetail {
        settingKeyword("$seen", isSeen)
    }

    func settingFlagged(_ isFlagged: Bool) -> EmailDetail {
        settingKeyword("$flagged", isFlagged)
    }

    private func settingKeyword(_ keyword: String, _ isSet: Bool) -> EmailDetail {
        var keywords = keywords ?? [:]
        if isSet {
            keywords[keyword] = true
        } else {
            keywords.removeValue(forKey: keyword)
        }

        return EmailDetail(
            id: id,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            receivedAt: receivedAt,
            sentAt: sentAt,
            messageId: messageId,
            inReplyTo: inReplyTo,
            references: references,
            preview: preview,
            keywords: keywords,
            textBody: textBody,
            htmlBody: htmlBody,
            bodyValues: bodyValues,
            attachments: attachments
        )
    }

    private func firstBodyValue(from parts: [EmailBodyPart]?) -> String? {
        parts?
            .compactMap(\.partId)
            .compactMap { bodyValues?[$0]?.value.nilIfEmpty }
            .first
    }
}

nonisolated struct EmailBodyValue: Hashable, Decodable {
    let value: String
    let isEncodingProblem: Bool?
    let isTruncated: Bool?
}

nonisolated extension DateFormatter {
    static let mailShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

nonisolated extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func htmlStripped() -> String {
        let decoded = replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        guard let data = decoded.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return decoded
        }

        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func htmlEscaped() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func htmlEntityDecoded() -> String {
        var decoded = self
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x22;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")
        return decoded
    }
}

import SwiftUI

/// A colour-coded tag — "Personal", "Work" — that some of the account's
/// aliases belong to.
///
/// Fastmail hands out as many addresses as you like on one account, and the
/// only thing separating work mail from personal mail is which of them a
/// message went to or came from. A tag names that split: its aliases colour
/// their messages in the list, and selecting the tag narrows every folder to
/// just that mail, which is the separated inbox without a second account.
///
/// Membership is stored as addresses rather than identity ids so a tag
/// survives the server reissuing an identity, and so one wildcard alias can
/// stand in for every address on a domain.
nonisolated struct MailTag: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var color: TagColor
    /// Lowercased, and kept in the form the server reports: a Fastmail
    /// wildcard alias arrives as `*@example.com` and is matched by domain.
    var addresses: [String]

    init(id: UUID = UUID(), name: String, color: TagColor, addresses: [String] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.addresses = addresses
    }

    /// Never empty: a tag caught mid-rename still has to label a row.
    var displayName: String {
        name.nilIfEmpty ?? "Untitled"
    }

    func contains(address: String) -> Bool {
        let wanted = address.lowercased()

        return addresses.contains { Self.pattern($0, matches: wanted) }
    }

    /// Whether this message is this tag's mail — delivered to one of its
    /// aliases, addressed to one, or sent from one. The sender half is what
    /// makes Sent and Drafts sort correctly, where your own address is in
    /// `from` and the recipients are everyone else's.
    func matches(_ email: EmailPreview) -> Bool {
        Self.correspondents(of: email).contains { contains(address: $0) }
    }

    /// This tag as an `Email/query` condition, so the server does the
    /// narrowing and paging keeps working on the result.
    ///
    /// `nil` for a tag with no aliases yet — an empty condition list would
    /// filter the mailbox down to nothing and read as lost mail.
    var jmapCondition: [String: Any]? {
        let values = Set(addresses.map(Self.filterText))
        guard !values.isEmpty else {
            return nil
        }

        // RFC 8621 §4.4.1 makes `from`/`to`/`cc` substring matches over the
        // header, which is why a wildcard alias can search for its domain and
        // an ordinary one for the whole address. `header` is the same section's
        // name/substring pair, and is what keeps relayed mail in the narrowed
        // folder rather than only labelling it in the unified one.
        let conditions: [[String: Any]] = values.sorted().flatMap {
            [["from": $0], ["to": $0], ["cc": $0], ["header": ["X-Delivered-To", $0]]]
        }

        return ["operator": "OR", "conditions": conditions]
    }

    /// Every address on a message that could identify it as one tag's mail.
    ///
    /// `deliveredTo` leads because it is the only one a relay can't hide: mail
    /// through Hide My Email or a forwarding iCloud address carries the
    /// relay's address in `to` and yours only here.
    static func correspondents(of email: EmailPreview) -> [String] {
        ((email.deliveredTo ?? []) + (email.from ?? []) + (email.to ?? []) + (email.cc ?? [])).map(\.email)
    }

    /// `*@example.com` and `@example.com` both mean every address at that
    /// domain — Fastmail's wildcard aliases, where one "address" covers an
    /// unbounded set.
    private static func pattern(_ pattern: String, matches address: String) -> Bool {
        let pattern = pattern.lowercased()

        guard let domain = wildcardDomain(pattern) else {
            return pattern == address
        }

        return address.hasSuffix(domain)
    }

    private static func wildcardDomain(_ pattern: String) -> String? {
        if pattern.hasPrefix("*@") {
            return String(pattern.dropFirst())
        }

        return pattern.hasPrefix("@") ? pattern : nil
    }

    /// What to hand the server for one alias. A wildcard has no literal form
    /// to match, so it searches for its domain instead.
    private static func filterText(_ address: String) -> String {
        let address = address.lowercased()

        return wildcardDomain(address) ?? address
    }

    // MARK: - New tags

    /// Names the first two tags after the split nearly everyone is making,
    /// and numbers the rest.
    static func suggestedName(existing: [MailTag]) -> String {
        let taken = Set(existing.map { $0.displayName.lowercased() })

        for name in ["Personal", "Work"] where !taken.contains(name.lowercased()) {
            return name
        }

        return "Tag \(existing.count + 1)"
    }

    /// Walks the palette so two tags added in a row don't come out identical.
    static func suggestedColor(existing: [MailTag]) -> TagColor {
        let used = Set(existing.map(\.color))

        return TagColor.allCases.first { !used.contains($0) } ?? .blue
    }
}

/// A fixed palette rather than a free colour well. These are read as caption
/// text on a list row, in both appearances, where an arbitrarily picked colour
/// is as likely to be illegible as not.
nonisolated enum TagColor: String, CaseIterable, Codable, Identifiable {
    case blue, indigo, purple, pink, red, orange, green, teal, brown

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .brown: .brown
        }
    }
}

nonisolated extension Array where Element == MailTag {
    /// The tag a message belongs to — the first whose aliases it involves. A
    /// message can reach two of your addresses at once, so the list's own
    /// order is the tiebreak and the answer stays stable between renders.
    func tag(for email: EmailPreview) -> MailTag? {
        first { $0.matches(email) }
    }
}

/// Where the tag list lives between launches. `MailStore` owns the in-memory
/// copy and is the only writer, so there is one source of truth rather than an
/// `@AppStorage` in every view that shows a tag.
nonisolated enum TagPreferences {
    static let tagsKey = "swift-mail.tags"
    static let activeTagKey = "swift-mail.tags.active"

    static func load(from defaults: UserDefaults = .standard) -> [MailTag] {
        guard let data = defaults.data(forKey: tagsKey) else {
            return []
        }

        // A tag list that no longer decodes is dropped rather than thrown:
        // starting untagged is the documented no-tags behaviour, where
        // failing here would be a mail app that won't open.
        return (try? JSONDecoder().decode([MailTag].self, from: data)) ?? []
    }

    static func save(_ tags: [MailTag], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(tags) else {
            return
        }

        defaults.set(data, forKey: tagsKey)
    }

    static func loadActiveID(from defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: activeTagKey).flatMap(UUID.init(uuidString:))
    }

    static func saveActiveID(_ id: UUID?, to defaults: UserDefaults = .standard) {
        defaults.set(id?.uuidString, forKey: activeTagKey)
    }
}

import Foundation

/// Someone this account has sent mail to, and how often.
nonisolated struct Recipient: Equatable, Codable {
    /// Lowercased — it is the identity of the row, and casing in an address is
    /// the sender's typing rather than a difference in who they are.
    let email: String
    let name: String?
    let sends: Int
    let lastSentAt: Date

    var address: EmailAddress {
        EmailAddress(name: name, email: email)
    }
}

/// Ranks and matches the addresses drawn from Sent.
///
/// Sent mail is used rather than an address book because it answers the
/// question the field is actually asking — who does this person write to —
/// and it needs no separate store to fall out of date. Everything here is
/// pure so the ranking can be pinned down in tests instead of being judged by
/// eye in a popup.
nonisolated enum RecipientIndex {
    /// How long it takes for a correspondent's history to count for half as
    /// much. Without it, someone written to fifty times two years ago outranks
    /// the person written to twice this week, which is the wrong answer nearly
    /// every time in mail.
    ///
    /// Three months, because six wasn't enough to actually settle that case —
    /// two years is only four half-lives at six months, which leaves a long-
    /// dead thread of fifty messages still ahead. At three it's eight, and the
    /// recent correspondent wins by an order of magnitude. Decay only reorders
    /// matches, never drops them, so erring short costs nothing.
    ///
    /// ponytail: one constant, not a model. Tune it if the ordering feels off.
    static let halfLife: TimeInterval = 90 * 24 * 60 * 60

    /// Frequency, aged.
    static func score(_ recipient: Recipient, now: Date = .now) -> Double {
        let age = max(0, now.timeIntervalSince(recipient.lastSentAt))
        return Double(recipient.sends) * pow(0.5, age / halfLife)
    }

    /// Whether a recipient answers what has been typed so far.
    ///
    /// Prefixes only, on the address and on each word of the name: `dec` finds
    /// `declan@…` and `Declan Wade`, and `wade` finds `Declan Wade` too. A
    /// substring match anywhere would make three letters match half the
    /// mailbox, which is how a completion list becomes noise.
    static func matches(_ recipient: Recipient, query: String) -> Bool {
        guard let query = query.nilIfEmpty?.lowercased() else {
            return false
        }

        if recipient.email.hasPrefix(query) {
            return true
        }

        // Once there's an `@`, the intent is clearly the address, and matching
        // the name as well would only put the wrong rows on screen.
        guard !query.contains("@"), let name = recipient.name?.lowercased() else {
            return false
        }

        return name.hasPrefix(query)
            || name.split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(query) }
    }

    /// The completion strings for what has been typed, best first.
    ///
    /// Returns the `Name <address>` form because that is what the token field
    /// round-trips through `EmailAddress(entry:)`; the token itself still
    /// shows only the friendly name.
    static func completions(
        for substring: String,
        in recipients: [Recipient],
        now: Date = .now,
        limit: Int = 10
    ) -> [String] {
        guard substring.nilIfEmpty != nil else {
            return []
        }

        return recipients
            .filter { matches($0, query: substring) }
            .sorted { left, right in
                let leftScore = score(left, now: now)
                let rightScore = score(right, now: now)

                guard leftScore == rightScore else {
                    return leftScore > rightScore
                }

                // A stable tiebreak so the list can't reshuffle between
                // keystrokes on two equally-ranked addresses.
                return left.email < right.email
            }
            .prefix(limit)
            .map(\.address.editableText)
    }

    /// Adds one message's recipients to the tally.
    ///
    /// Counts accumulate and the most recent non-empty name wins — an address
    /// written to before the sender had a name for it shouldn't keep showing
    /// as a bare address forever, and a name that has since changed shouldn't
    /// be pinned to the first one ever seen.
    static func folding(
        _ addresses: some Sequence<EmailAddress>,
        sentAt: Date,
        into tally: inout [String: Recipient]
    ) {
        for address in addresses {
            guard let email = address.email.nilIfEmpty?.lowercased() else {
                continue
            }

            guard let existing = tally[email] else {
                tally[email] = Recipient(
                    email: email,
                    name: address.name?.nilIfEmpty,
                    sends: 1,
                    lastSentAt: sentAt
                )
                continue
            }

            let isNewer = sentAt >= existing.lastSentAt

            tally[email] = Recipient(
                email: email,
                name: (isNewer ? address.name?.nilIfEmpty : nil) ?? existing.name,
                sends: existing.sends + 1,
                lastSentAt: max(existing.lastSentAt, sentAt)
            )
        }
    }

    /// Every address a sent message was addressed to. `Email/get` doesn't
    /// return Bcc for a message once it's in Sent, so the Bcc side of the index
    /// comes from the send path rather than from here.
    static func addressed(in preview: EmailPreview) -> [EmailAddress] {
        (preview.to ?? []) + (preview.cc ?? [])
    }
}

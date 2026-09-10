import Foundation

/// One Fastmail Masked Email address.
///
/// Fastmail's JMAP extension (`https://www.fastmail.com/dev/maskedemail`), not
/// part of the IETF spec — so the capability is checked at runtime the way
/// snooze is, rather than assumed.
nonisolated struct MaskedEmail: Identifiable, Hashable, Codable {
    let id: String
    let email: String
    var state: MaskedEmailState
    /// Fastmail names this `description`. Renamed here so it can't be confused
    /// with `CustomStringConvertible`, and because what it holds is a note
    /// about who the address was made for.
    var note: String?
    /// The site the address was created for, when the creator said.
    var forDomain: String?
    let url: String?
    let createdAt: Date?
    /// Nil until the address has actually received something.
    let lastMessageAt: Date?
    let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case state
        case note = "description"
        case forDomain
        case url
        case createdAt
        case lastMessageAt
        case createdBy
    }

    /// What to call this address in a list. The note is what someone typed, so
    /// it wins; the domain is what the creating app filled in; failing both,
    /// the address speaks for itself.
    var displayName: String {
        note?.nilIfEmpty ?? forDomain?.nilIfEmpty ?? email
    }

    /// Matches the address, the note and the domain, so searching "netflix"
    /// finds it however it was labelled.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return true
        }

        return [email, note, forDomain, createdBy]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Newest activity first: an address that just received mail is the one
    /// being looked for, and one never used yet sorts by when it was made.
    static func inUseOrder(_ lhs: MaskedEmail, _ rhs: MaskedEmail) -> Bool {
        let left = lhs.lastMessageAt ?? lhs.createdAt ?? .distantPast
        let right = rhs.lastMessageAt ?? rhs.createdAt ?? .distantPast

        if left != right {
            return left > right
        }

        return lhs.email < rhs.email
    }
}

/// Fastmail's four states.
///
/// `unknown` exists because this is a vendor extension: a state added later
/// should show up as an address the app won't pretend to understand, not as a
/// decode failure that hides every other address in the response.
nonisolated enum MaskedEmailState: String, Codable, Hashable, CaseIterable {
    /// Created but never used. Fastmail deletes these 24 hours after creation,
    /// and promotes them to `enabled` if mail arrives first.
    case pending
    case enabled
    /// Still accepts mail, but it goes straight to Trash.
    case disabled
    /// Bounces. Recoverable — this is a state, not a destroy.
    case deleted
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MaskedEmailState(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .enabled: return "Active"
        case .disabled: return "Blocked"
        case .deleted: return "Deleted"
        case .unknown: return "Unknown"
        }
    }

    /// Whether mail sent here still reaches the inbox.
    var isReceiving: Bool {
        self == .enabled || self == .pending
    }
}

import Foundation

/// Power-search syntax (`from:ana subject:"q3 report" after:7d -is:read`).
///
/// Every operator here maps straight onto a JMAP `FilterCondition` key, so the
/// server does the searching and this type only translates. Unknown operators
/// fall through to free text rather than erroring, so a half-typed query still
/// returns something useful.
nonisolated struct SearchQuery {
    enum Field: String, CaseIterable {
        case from, to, cc, bcc, subject, body, text
        case has, `is`, `in`, before, after

        /// Shown beside the operator in the autocomplete list.
        var hint: String {
            switch self {
            case .from: "Sender address or name"
            case .to: "Recipient"
            case .cc: "Carbon copy recipient"
            case .bcc: "Blind copy recipient"
            case .subject: "Words in the subject"
            case .body: "Words in the message body"
            case .text: "Words anywhere in the message"
            case .has: "Attachments"
            case .is: "Read, flagged, draft…"
            case .in: "Mailbox to search"
            case .before: "On or before a date"
            case .after: "On or after a date"
            }
        }
    }

    struct Term: Equatable {
        /// `nil` means a bare word, searched as free text.
        let field: Field?
        let value: String
        let isNegated: Bool
    }

    let terms: [Term]

    init(_ input: String) {
        terms = Self.parse(input)
    }

    // MARK: - Parsing

    /// Splits on whitespace, treating a double-quoted run as one token so
    /// `subject:"quarterly report"` survives intact.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false

        for character in input {
            if character == "\"" {
                isQuoted.toggle()
            } else if character.isWhitespace && !isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private static func parse(_ input: String) -> [Term] {
        tokenize(input).compactMap { token in
            var raw = token
            var isNegated = false

            if raw.hasPrefix("-"), raw.count > 1 {
                isNegated = true
                raw.removeFirst()
            }

            guard let colon = raw.firstIndex(of: ":") else {
                return Term(field: nil, value: raw, isNegated: isNegated)
            }

            let name = raw[raw.startIndex..<colon].lowercased()
            let value = String(raw[raw.index(after: colon)...])

            guard let field = Field(rawValue: name) else {
                // Not an operator (a bare URL, a time like "9:30") — literal text.
                return Term(field: nil, value: token, isNegated: false)
            }

            // A dangling `from:` is mid-typing, not a search for the word "from:".
            return value.isEmpty ? nil : Term(field: field, value: value, isNegated: isNegated)
        }
    }

    // MARK: - JMAP

    /// Builds the `Email/query` filter. `nil` means "no constraints at all",
    /// which the caller should send as an omitted filter.
    func jmapFilter(mailboxID: String?, mailboxes: [Mailbox] = [], now: Date = Date()) -> [String: Any]? {
        var conditions: [[String: Any]] = []

        // An explicit `in:` overrides the selected mailbox; `in:all` unscopes.
        if let scope = terms.last(where: { $0.field == .in && !$0.isNegated }) {
            if !Self.everywhere.contains(scope.value.lowercased()) {
                // An unresolved name stays as the literal id so the query
                // returns nothing, rather than silently searching elsewhere.
                conditions.append(["inMailbox": Self.mailboxID(named: scope.value, in: mailboxes) ?? scope.value])
            }
        } else if let mailboxID {
            conditions.append(["inMailbox": mailboxID])
        }

        var freeText: [String] = []

        for term in terms where term.field != .in {
            if term.field == nil, !term.isNegated {
                freeText.append(term.value)
                continue
            }

            guard let condition = Self.condition(for: term, now: now) else {
                continue
            }

            conditions.append(term.isNegated ? ["operator": "NOT", "conditions": [condition]] : condition)
        }

        if !freeText.isEmpty {
            conditions.append(["text": freeText.joined(separator: " ")])
        }

        switch conditions.count {
        case 0: return nil
        case 1: return conditions[0]
        default: return ["operator": "AND", "conditions": conditions]
        }
    }

    private static func condition(for term: Term, now: Date) -> [String: Any]? {
        guard let field = term.field else {
            return ["text": term.value]
        }

        switch field {
        case .from, .to, .cc, .bcc, .subject, .body, .text:
            return [field.rawValue: term.value]
        case .has:
            return attachmentValues.contains(term.value.lowercased()) ? ["hasAttachment": true] : nil
        case .is:
            let value = term.value.lowercased()

            // Thread-level first: `is:muted` asks about the conversation, not
            // the one message, and RFC 8621 4.4.1 has separate conditions for
            // that question.
            if let thread = threadKeywords[value] {
                return [thread.condition: thread.keyword]
            }

            guard let flag = keywords[value] else {
                return nil
            }

            return [flag.isSet ? "hasKeyword" : "notKeyword": flag.keyword]
        case .before, .after:
            guard let date = date(from: term.value, now: now) else {
                return nil
            }

            return [field.rawValue: utcDateFormatter.string(from: date)]
        case .in:
            return nil // Handled as mailbox scope above.
        }
    }

    private static func mailboxID(named name: String, in mailboxes: [Mailbox]) -> String? {
        let wanted = name.lowercased()
        return mailboxes.first { $0.displayName.lowercased() == wanted || $0.name.lowercased() == wanted }?.id
    }

    // MARK: - Dates

    /// Accepts `2024-03-01`, `2024-03`, `2024`, `today`, `yesterday` and
    /// relative offsets like `7d`, `2w`, `3m`, `1y`. Everything resolves to the
    /// start of a day so `after:today` means "since midnight", not "since now".
    static func date(from value: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let lowered = value.lowercased()

        switch lowered {
        case "today":
            return calendar.startOfDay(for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            break
        }

        if let unit = lowered.last, let component = relativeUnits[unit],
           let amount = Int(lowered.dropLast()), amount > 0 {
            return calendar.date(byAdding: component, value: -amount, to: calendar.startOfDay(for: now))
        }

        let parts = lowered.split(separator: "-").map(String.init)
        guard let first = parts.first, first.count == 4, let year = Int(first), parts.count <= 3 else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = parts.count > 1 ? Int(parts[1]) : 1
        components.day = parts.count > 2 ? Int(parts[2]) : 1

        guard components.month != nil, components.day != nil else {
            return nil
        }

        return calendar.date(from: components)
    }

    private static let relativeUnits: [Character: Calendar.Component] = [
        "d": .day,
        "w": .weekOfYear,
        "m": .month,
        "y": .year
    ]

    private static let utcDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // MARK: - Vocabularies

    private static let everywhere: Set<String> = ["all", "anywhere", "everywhere", "*"]
    private static let attachmentValues: Set<String> = ["attachment", "attachments", "file"]

    /// `is:` values, mapped to the JMAP keyword and whether it must be present.
    static let keywords: [String: (keyword: String, isSet: Bool)] = [
        "read": ("$seen", true),
        "unread": ("$seen", false),
        "flagged": ("$flagged", true),
        "starred": ("$flagged", true),
        "unflagged": ("$flagged", false),
        "draft": ("$draft", true),
        "answered": ("$answered", true),
        "replied": ("$answered", true),
        "forwarded": ("$forwarded", true)
    ]

    /// `is:` values that ask about a whole conversation rather than one
    /// message. `someInThreadHaveKeyword` finds the thread if any message
    /// carries it; `noneInThreadHaveKeyword` is the exact complement, which is
    /// what makes muting a thread stick even after part of it is read or filed.
    static let threadKeywords: [String: (keyword: String, condition: String)] = [
        "muted": ("$muted", "someInThreadHaveKeyword"),
        "unmuted": ("$muted", "noneInThreadHaveKeyword")
    ]

    /// Excludes muted conversations. The Inbox applies this to every listing;
    /// searching `is:muted` is how they are found again.
    static let notMutedCondition: [String: Any] = ["noneInThreadHaveKeyword": "$muted"]

    static let mutedKeyword = "$muted"
}

// MARK: - Quick filters

extension SearchQuery {
    /// The toolbar's one-click filters. Each is just an operator the search
    /// field already understands, so a filter and a typed query compose
    /// instead of competing, and neither needs its own query pipeline.
    enum QuickFilter: String, CaseIterable, Identifiable {
        case unread = "is:unread"
        case flagged = "is:flagged"
        case hasAttachment = "has:attachment"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .unread: "Unread"
            case .flagged: "Flagged"
            case .hasAttachment: "Has Attachment"
            }
        }

        var icon: String {
            switch self {
            case .unread: "envelope.badge"
            case .flagged: "flag"
            case .hasAttachment: "paperclip"
            }
        }
    }

    static func contains(_ token: String, in query: String) -> Bool {
        tokenize(query).contains { $0.caseInsensitiveCompare(token) == .orderedSame }
    }

    /// Adds or removes one operator token, leaving everything else the user
    /// typed intact.
    static func toggling(_ token: String, in query: String) -> String {
        var tokens = tokenize(query)

        if let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            tokens.remove(at: index)
        } else {
            tokens.append(token)
        }

        return tokens.map(requoted).joined(separator: " ")
    }

    /// Re-quotes a token that holds whitespace, so rebuilding a query string
    /// from its tokens round-trips back through `tokenize` unchanged.
    private static func requoted(_ token: String) -> String {
        guard token.contains(where: \.isWhitespace) else {
            return token
        }

        guard let colon = token.firstIndex(of: ":") else {
            return "\"\(token)\""
        }

        return token[...colon] + "\"" + token[token.index(after: colon)...] + "\""
    }
}

// MARK: - Autocomplete

extension SearchQuery {
    struct Suggestion: Identifiable, Hashable {
        /// The full replacement search text, not just the fragment.
        let completion: String
        let label: String
        let detail: String

        var id: String { completion }
    }

    /// Suggestions for the token currently being typed. Addresses come from the
    /// messages already on screen, so this costs nothing and hits no network.
    static func suggestions(
        for input: String,
        mailboxes: [Mailbox] = [],
        emails: [EmailPreview] = [],
        limit: Int = 8
    ) -> [Suggestion] {
        // Mid-quote: the token boundaries are ambiguous, so stay quiet.
        guard input.count(where: { $0 == "\"" }).isMultiple(of: 2) else {
            return []
        }

        let head: String
        let token: String

        if let boundary = input.lastIndex(where: \.isWhitespace) {
            head = String(input[...boundary])
            token = String(input[input.index(after: boundary)...])
        } else {
            head = ""
            token = input
        }

        var bare = token
        let negation = bare.hasPrefix("-") && bare.count > 1 ? "-" : ""
        if !negation.isEmpty {
            bare.removeFirst()
        }

        if let colon = bare.firstIndex(of: ":"),
           let field = Field(rawValue: bare[bare.startIndex..<colon].lowercased()) {
            let partial = bare[bare.index(after: colon)...].lowercased()

            return values(for: field, mailboxes: mailboxes, emails: emails)
                .filter { $0.value.lowercased().hasPrefix(partial) }
                .prefix(limit)
                .map {
                    Suggestion(
                        completion: head + negation + field.rawValue + ":" + quoting($0.value),
                        label: field.rawValue + ":" + $0.value,
                        detail: $0.detail
                    )
                }
        }

        let partial = bare.lowercased()

        return Field.allCases
            .filter { $0.rawValue.hasPrefix(partial) }
            .prefix(limit)
            .map {
                Suggestion(
                    completion: head + negation + $0.rawValue + ":",
                    label: $0.rawValue + ":",
                    detail: $0.hint
                )
            }
    }

    private static func values(
        for field: Field,
        mailboxes: [Mailbox],
        emails: [EmailPreview]
    ) -> [(value: String, detail: String)] {
        switch field {
        case .is:
            return (Array(keywords.keys) + Array(threadKeywords.keys)).sorted().map {
                ($0, threadKeywords[$0] != nil ? "The whole conversation" : "")
            }
        case .has:
            return [("attachment", "Messages with a file attached")]
        case .in:
            return [("all", "Every mailbox")] + mailboxes.map { ($0.displayName, "") }
        case .from, .to, .cc, .bcc:
            return addresses(in: emails)
        case .before, .after:
            return [
                ("today", ""),
                ("yesterday", ""),
                ("7d", "7 days ago"),
                ("30d", "30 days ago"),
                ("1y", "A year ago"),
                (String(Calendar.current.component(.year, from: Date())), "Start of the year")
            ]
        case .subject, .body, .text:
            return []
        }
    }

    /// Addresses harvested from the loaded previews, most recent first.
    private static func addresses(in emails: [EmailPreview]) -> [(value: String, detail: String)] {
        var seen: Set<String> = []
        var results: [(value: String, detail: String)] = []

        for address in emails.flatMap({ ($0.from ?? []) + ($0.to ?? []) }) {
            let email = address.email.lowercased()
            guard !email.isEmpty, seen.insert(email).inserted else {
                continue
            }

            results.append((email, address.name ?? ""))
        }

        return results
    }

    private static func quoting(_ value: String) -> String {
        value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }
}

import Foundation
import Testing
@testable import swift_mail

struct SearchQueryTests {
    private let mailboxes = [
        Mailbox(id: "mb1", name: "Inbox", role: "inbox", parentId: nil, sortOrder: nil, totalEmails: nil, unreadEmails: nil),
        Mailbox(id: "mb2", name: "Work Stuff", role: nil, parentId: nil, sortOrder: nil, totalEmails: nil, unreadEmails: nil)
    ]

    private func filter(_ query: String, mailboxID: String? = "inbox-id", now: Date = Date()) -> [String: Any]? {
        SearchQuery(query).jmapFilter(mailboxID: mailboxID, mailboxes: mailboxes, now: now)
    }

    private func conditions(_ query: String) -> [[String: Any]] {
        (filter(query)?["conditions"] as? [[String: Any]]) ?? []
    }

    @Test("A bare query stays a mailbox-scoped text search")
    func plainText() {
        let conditions = conditions("quarterly report")

        #expect(conditions.count == 2)
        #expect(conditions[0]["inMailbox"] as? String == "inbox-id")
        #expect(conditions[1]["text"] as? String == "quarterly report")
    }

    @Test("Operators map onto their JMAP fields, quotes hold phrases together")
    func operatorsMapToJMAP() {
        let conditions = conditions("from:ana subject:\"q3 report\" has:attachment is:unread")

        #expect(conditions.contains { $0["from"] as? String == "ana" })
        #expect(conditions.contains { $0["subject"] as? String == "q3 report" })
        #expect(conditions.contains { $0["hasAttachment"] as? Bool == true })
        #expect(conditions.contains { $0["notKeyword"] as? String == "$seen" })
    }

    @Test("A leading dash negates a term")
    func negation() {
        let negated = conditions("-from:spam@example.com").first { $0["operator"] as? String == "NOT" }
        let inner = (negated?["conditions"] as? [[String: Any]])?.first

        #expect(inner?["from"] as? String == "spam@example.com")
    }

    @Test("in: overrides the selected mailbox and in:all unscopes entirely")
    func mailboxScope() {
        #expect(conditions("in:\"Work Stuff\" budget").contains { $0["inMailbox"] as? String == "mb2" })
        #expect(!conditions("in:all budget").contains { $0["inMailbox"] != nil })
        // An unknown folder must not silently fall back to the current mailbox.
        #expect(conditions("in:Nowhere budget").contains { $0["inMailbox"] as? String == "Nowhere" })
    }

    @Test("Dates accept absolute, named and relative forms")
    func dateParsing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 14))!

        #expect(SearchQuery.date(from: "today", now: now, calendar: calendar) == calendar.startOfDay(for: now))
        #expect(SearchQuery.date(from: "2024-03-01", now: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2024, month: 3, day: 1)))
        #expect(SearchQuery.date(from: "2024", now: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        #expect(SearchQuery.date(from: "7d", now: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        #expect(SearchQuery.date(from: "notadate", now: now, calendar: calendar) == nil)
    }

    @Test("after: emits a UTC timestamp JMAP accepts")
    func dateCondition() {
        let after = conditions("after:2024-03-01").first { $0["after"] != nil }?["after"] as? String

        #expect(after?.hasSuffix("Z") == true)
        #expect(after?.contains("2024-02-29") == true || after?.contains("2024-03-01") == true)
    }

    @Test("A colon that isn't an operator is searched literally")
    func nonOperatorColon() {
        #expect(conditions("standup 9:30").contains { $0["text"] as? String == "standup 9:30" })
    }

    @Test("A half-typed operator doesn't leak into the query as text")
    func danglingOperator() {
        #expect(filter("from:") == nil || conditions("from:").allSatisfy { $0["text"] == nil })
    }

    @Test("Toggling a quick filter adds and removes only its own token")
    func quickFilterToggling() {
        let unread = SearchQuery.QuickFilter.unread.rawValue

        #expect(SearchQuery.toggling(unread, in: "") == "is:unread")
        #expect(SearchQuery.toggling(unread, in: "budget") == "budget is:unread")
        #expect(SearchQuery.toggling(unread, in: "budget is:unread") == "budget")
        #expect(SearchQuery.toggling(unread, in: "is:unread has:attachment") == "has:attachment")

        #expect(SearchQuery.contains(unread, in: "budget is:unread"))
        #expect(!SearchQuery.contains(unread, in: "budget is:read"))
        // A word merely containing the token isn't the token.
        #expect(!SearchQuery.contains(unread, in: "subject:is:unread"))
    }

    @Test("Toggling round-trips a quoted phrase instead of splitting it")
    func togglingPreservesQuotedPhrases() {
        let toggled = SearchQuery.toggling("is:flagged", in: "subject:\"q3 report\" from:ana")

        #expect(SearchQuery.tokenize(toggled) == ["subject:q3 report", "from:ana", "is:flagged"])

        let conditions = (SearchQuery(toggled).jmapFilter(mailboxID: "mb", mailboxes: [])?["conditions"] as? [[String: Any]]) ?? []
        #expect(conditions.contains { $0["subject"] as? String == "q3 report" })
        #expect(conditions.contains { $0["hasKeyword"] as? String == "$flagged" })
    }

    @Test("Every quick filter maps to a real JMAP condition")
    func quickFiltersProduceConditions() {
        for filter in SearchQuery.QuickFilter.allCases {
            let conditions = (SearchQuery(filter.rawValue)
                .jmapFilter(mailboxID: "mb", mailboxes: [])?["conditions"] as? [[String: Any]]) ?? []

            // The mailbox scope plus the filter's own condition.
            #expect(conditions.count == 2, "\(filter.rawValue) produced \(conditions)")
        }
    }

    @Test("Suggestions complete operators and their values against the full query")
    func suggestions() {
        let fields = SearchQuery.suggestions(for: "budget su", mailboxes: mailboxes)
        #expect(fields.first?.completion == "budget subject:")

        let folders = SearchQuery.suggestions(for: "in:wor", mailboxes: mailboxes)
        #expect(folders.first?.completion == "in:\"Work Stuff\"")

        let flags = SearchQuery.suggestions(for: "-is:unr", mailboxes: mailboxes)
        #expect(flags.first?.completion == "-is:unread")

        // Mid-phrase, token boundaries are ambiguous — stay quiet.
        #expect(SearchQuery.suggestions(for: "subject:\"q3 rep", mailboxes: mailboxes).isEmpty)
    }
}

import Foundation
import Testing
@testable import swift_mail

/// The sweep's safety property: a query that says nothing must never resolve to
/// a filter, because a filter with only `inMailbox` means "every message in this
/// folder" — and sweep moves what it matches.
struct SweepFilterTests {
    private let mailboxes = [
        Mailbox(id: "mb1", name: "Inbox", role: "inbox", parentId: nil, sortOrder: nil, totalEmails: nil, unreadEmails: nil),
        Mailbox(id: "mb2", name: "Archive", role: "archive", parentId: nil, sortOrder: nil, totalEmails: nil, unreadEmails: nil)
    ]

    private func filter(_ query: String, mailboxID: String? = "mb1") -> [String: Any]? {
        MailStore.sweepFilter(query: query, mailboxID: mailboxID, mailboxes: mailboxes)
    }

    /// A single condition comes back unwrapped rather than inside an `AND`.
    private func conditions(_ query: String) -> [[String: Any]] {
        guard let filter = filter(query) else {
            return []
        }

        return (filter["conditions"] as? [[String: Any]]) ?? [filter]
    }

    @Test("An empty or blank query sweeps nothing")
    func blankQueryYieldsNoFilter() {
        #expect(filter("") == nil)
        #expect(filter("   ") == nil)
        #expect(filter("\n\t ") == nil)
        // Quotes that enclose nothing are still nothing.
        #expect(filter("\"\"") == nil)
    }

    @Test("No selected mailbox sweeps nothing")
    func noMailboxYieldsNoFilter() {
        #expect(filter("is:read", mailboxID: nil) == nil)
    }

    @Test("A real query is scoped to the current folder")
    func realQueryIsScoped() {
        let conditions = conditions("is:read")

        #expect(conditions.contains { $0["inMailbox"] as? String == "mb1" })
        #expect(conditions.contains { $0["hasKeyword"] as? String == "$seen" })
    }

    @Test("in:all widens the sweep past the current folder")
    func inAllUnscopes() {
        let conditions = conditions("in:all is:read")

        #expect(!conditions.contains { $0["inMailbox"] != nil })
        #expect(conditions.contains { $0["hasKeyword"] as? String == "$seen" })
    }

    @Test("in:all on its own has no conditions at all, so it sweeps nothing")
    func bareInAllSweepsNothing() {
        // Otherwise this would mean every message in the account.
        #expect(filter("in:all") == nil)
    }
}

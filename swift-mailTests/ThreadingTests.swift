//
//  ThreadingTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// Collapsing the list to one row per conversation changes what a row *means*,
/// and three things quietly depend on getting that right: `Thread/get` has to
/// come back keyed the way the row reads it, `is:muted` has to compile to a
/// thread condition rather than a message one, and the Inbox's own exclusion
/// has to agree with the operator the user can type.
struct ThreadingTests {

    // MARK: - Thread membership

    @Test("Thread/get is read into a thread-to-messages lookup")
    func threadMembership() {
        let payload: [String: Any] = [
            "list": [
                ["id": "T1", "emailIds": ["E3", "E2", "E1"]],
                ["id": "T2", "emailIds": ["E9"]]
            ]
        ]

        let membership = JMAPClient.threadMembership(in: payload)

        #expect(membership["T1"] == ["E3", "E2", "E1"])
        #expect(membership["T2"] == ["E9"])
    }

    @Test("A malformed or absent Thread/get leaves the lookup empty, not wrong")
    func threadMembershipDegrades() {
        #expect(JMAPClient.threadMembership(in: [:]).isEmpty)
        #expect(JMAPClient.threadMembership(in: ["list": "nonsense"]).isEmpty)
        // A thread without an id can't be looked up, so it is dropped rather
        // than keyed on something invented.
        #expect(JMAPClient.threadMembership(in: ["list": [["emailIds": ["E1"]]]]).isEmpty)
    }

    // MARK: - Muting

    @Test("is:muted asks about the conversation, not the message")
    func mutedIsAThreadCondition() throws {
        let filter = try #require(SearchQuery("is:muted").jmapFilter(mailboxID: nil))

        // someInThreadHaveKeyword, because one muted message mutes the thread —
        // hasKeyword would only find the messages actually carrying it.
        #expect(filter["someInThreadHaveKeyword"] as? String == "$muted")
        #expect(filter["hasKeyword"] == nil)
    }

    @Test("is:unmuted is the exact complement")
    func unmutedIsTheComplement() throws {
        let filter = try #require(SearchQuery("is:unmuted").jmapFilter(mailboxID: nil))

        #expect(filter["noneInThreadHaveKeyword"] as? String == "$muted")
    }

    @Test("The exclusion the Inbox listing applies matches is:unmuted")
    func inboxExclusionMatchesTheOperator() {
        #expect(SearchQuery.notMutedCondition["noneInThreadHaveKeyword"] as? String == SearchQuery.mutedKeyword)
    }

    @Test("Message-level keywords still compile to message conditions")
    func messageKeywordsAreUnaffected() throws {
        let unread = try #require(SearchQuery("is:unread").jmapFilter(mailboxID: nil))
        #expect(unread["notKeyword"] as? String == "$seen")

        let flagged = try #require(SearchQuery("is:flagged").jmapFilter(mailboxID: nil))
        #expect(flagged["hasKeyword"] as? String == "$flagged")
    }

    @Test("A thread term combines with the rest of the query rather than replacing it")
    func mutedComposesWithOtherTerms() throws {
        let filter = try #require(
            SearchQuery("is:muted from:ana").jmapFilter(mailboxID: "MB1")
        )

        let conditions = try #require(filter["conditions"] as? [[String: Any]])
        #expect(filter["operator"] as? String == "AND")
        #expect(conditions.contains { $0["inMailbox"] as? String == "MB1" })
        #expect(conditions.contains { $0["someInThreadHaveKeyword"] as? String == "$muted" })
        #expect(conditions.contains { $0["from"] as? String == "ana" })
    }

    // MARK: - Grouping preference

    @Test("Grouping is on by default, because the stored flag is the opt-out")
    func groupingDefaultsOn() throws {
        let name = "threading-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(!defaults.bool(forKey: ThreadPreferences.ungroupedKey))

        ThreadPreferences.setGroupsIntoThreads(false, in: defaults)
        #expect(defaults.bool(forKey: ThreadPreferences.ungroupedKey))

        ThreadPreferences.setGroupsIntoThreads(true, in: defaults)
        #expect(!defaults.bool(forKey: ThreadPreferences.ungroupedKey))
    }

    // MARK: - Paging

    private func arguments(anchor: String?, position: Int = 40) -> [String: Any] {
        JMAPClient.queryArguments(
            accountID: "u1",
            filter: ["inMailbox": "MB1"],
            position: position,
            anchor: anchor,
            anchorOffset: anchor == nil ? 0 : 1,
            limit: 50,
            collapseThreads: true
        )
    }

    @Test("The first page asks by position, with no anchor")
    func firstPageUsesPosition() {
        let first = arguments(anchor: nil, position: 0)

        #expect(first["position"] as? Int == 0)
        #expect(first["anchor"] == nil)
        #expect(first["anchorOffset"] == nil)
    }

    @Test("Later pages anchor on the last row and drop position entirely")
    func laterPagesAnchor() {
        let next = arguments(anchor: "E40")

        // Both would be a contradiction the server resolves by ignoring
        // position (RFC 8620 5.5) — sending only one keeps the request honest
        // about what it means.
        #expect(next["anchor"] as? String == "E40")
        #expect(next["anchorOffset"] as? Int == 1)
        #expect(next["position"] == nil)
    }

    @Test("Paging asks for the row after the anchor, not the anchor again")
    func anchorOffsetSkipsTheAnchor() {
        // Offset 0 would return the last row the list already holds, and the
        // dedup would then silently shorten every page by one.
        #expect(arguments(anchor: "E40")["anchorOffset"] as? Int == 1)
    }

    @Test("Every page carries the grouping mode it was fetched for")
    func pagingKeepsGroupingConsistent() {
        #expect(arguments(anchor: nil)["collapseThreads"] as? Bool == true)
        #expect(arguments(anchor: "E40")["collapseThreads"] as? Bool == true)
    }
}

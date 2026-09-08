//
//  BackgroundSyncTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

struct BackgroundSyncTests {
    private func decodePreview(_ json: String) throws -> EmailPreview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EmailPreview.self, from: Data(json.utf8))
    }

    @Test("A StateChange exposes the new per-type state for an account")
    func stateChangeDecoding() throws {
        let json = """
        {
            "@type": "StateChange",
            "changed": {
                "acc-1": { "Email": "e-99", "Mailbox": "m-42" },
                "acc-2": { "Email": "x-1" }
            }
        }
        """

        let change = try JSONDecoder().decode(JMAPStateChange.self, from: Data(json.utf8))

        #expect(change.state(for: "Email", accountID: "acc-1") == "e-99")
        #expect(change.state(for: "Mailbox", accountID: "acc-1") == "m-42")
        #expect(change.state(for: "Mailbox", accountID: "acc-2") == nil)
        #expect(change.state(for: "Email", accountID: "missing") == nil)
    }

    @Test("A new unread Inbox message warrants a notification")
    func notifiableWhenNewUnreadInbox() throws {
        let now = Date()
        let preview = try decodePreview("""
        {
            "id": "E1",
            "mailboxIds": { "inbox-1": true },
            "keywords": {},
            "receivedAt": "\(ISO8601DateFormatter().string(from: now))"
        }
        """)

        #expect(preview.warrantsNotification(inboxMailboxID: "inbox-1", now: now))
    }

    @Test("Already-read, non-Inbox, or stale messages do not notify")
    func notNotifiableCases() throws {
        let now = Date()

        let read = try decodePreview("""
        { "id": "E2", "mailboxIds": { "inbox-1": true }, "keywords": { "$seen": true } }
        """)
        #expect(!read.warrantsNotification(inboxMailboxID: "inbox-1", now: now))

        let elsewhere = try decodePreview("""
        { "id": "E3", "mailboxIds": { "archive-1": true }, "keywords": {} }
        """)
        #expect(!elsewhere.warrantsNotification(inboxMailboxID: "inbox-1", now: now))

        let stale = try decodePreview("""
        {
            "id": "E4",
            "mailboxIds": { "inbox-1": true },
            "keywords": {},
            "receivedAt": "\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200)))"
        }
        """)
        #expect(!stale.warrantsNotification(inboxMailboxID: "inbox-1", now: now))
    }

    @Test("threadId decodes and survives a keyword edit")
    func threadIDRoundTrips() throws {
        let preview = try decodePreview("""
        { "id": "E5", "threadId": "T-7", "keywords": {} }
        """)

        #expect(preview.threadId == "T-7")
        #expect(preview.settingSeen(true).threadId == "T-7")
    }
}

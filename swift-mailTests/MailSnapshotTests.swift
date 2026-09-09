//
//  MailSnapshotTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// The cache's two obligations: give back exactly what went in, and throw
/// itself away rather than hand over something it can't vouch for.
struct MailSnapshotTests {
    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID().uuidString).json")
    }

    /// An `EmailPreview` as the server sends one, including the delivery header
    /// whose coding key is not a plain property name.
    private func preview() throws -> EmailPreview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(EmailPreview.self, from: Data("""
        {
            "id": "E1",
            "subject": "Quarterly invoice",
            "receivedAt": "2026-09-09T02:15:00Z",
            "keywords": { "$seen": true },
            "to": [{ "email": "a1b2c3@privaterelay.appleid.com" }],
            "header:X-Delivered-To:asAddresses": [{ "email": "declan@example.com" }]
        }
        """.utf8))
    }

    private func snapshot(previews: [EmailPreview], accountKey: String = "acct-a") -> MailSnapshot {
        MailSnapshot(
            accountKey: accountKey,
            emailState: "2f9e:8821",
            mailboxState: "41ab:07",
            mailboxes: [
                Mailbox(id: "mb1", name: "Inbox", role: "inbox", parentId: nil, sortOrder: 0, totalEmails: 12, unreadEmails: 3)
            ],
            identities: [
                MailIdentity(id: "id1", name: "Declan", email: "declan@example.com", replyTo: nil, bcc: nil, textSignature: nil, htmlSignature: nil)
            ],
            selectedMailboxID: "mb1",
            previews: ["mb1": previews]
        )
    }

    @Test("A saved snapshot comes back whole")
    func roundTrip() throws {
        let file = scratchFile()
        let original = snapshot(previews: [try preview()])

        MailSnapshotStore.save(original, to: file)
        let restored = try #require(MailSnapshotStore.load(accountKey: "acct-a", from: file))

        // The cursors are the reason the file exists: without them the first
        // sync of a launch has nothing to diff against.
        #expect(restored.emailState == "2f9e:8821")
        #expect(restored.mailboxState == "41ab:07")
        #expect(restored.selectedMailboxID == "mb1")
        #expect(restored.mailboxes.first?.unreadEmails == 3)
        #expect(restored.identities.first?.email == "declan@example.com")
        #expect(restored.previews["mb1"]?.first?.subject == "Quarterly invoice")
        #expect(restored.previews["mb1"]?.first?.isUnread == false)
        #expect(restored.previews["mb1"]?.first?.receivedAt == (try preview().receivedAt))
    }

    @Test("A restored message still knows which alias it was delivered to")
    func deliveryHeaderSurvivesTheRoundTrip() throws {
        let file = scratchFile()
        MailSnapshotStore.save(snapshot(previews: [try preview()]), to: file)

        let restored = try #require(MailSnapshotStore.load(accountKey: "acct-a", from: file))
        let cached = try #require(restored.previews["mb1"]?.first)

        // `deliveredTo` encodes under "header:X-Delivered-To:asAddresses", not a
        // plain property name. Losing it in the round trip would leave relayed
        // mail silently untagged on every launch until the first sync landed.
        let work = MailTag(name: "Work", color: .blue, addresses: ["declan@example.com"])
        #expect(cached.deliveredTo?.first?.email == "declan@example.com")
        #expect(work.matches(cached))
    }

    @Test("A cache it can't vouch for is discarded, not repaired")
    func rejectsWhatItCannotTrust() throws {
        let file = scratchFile()
        MailSnapshotStore.save(snapshot(previews: [try preview()]), to: file)

        // Another account's mail must never surface under this one.
        #expect(MailSnapshotStore.load(accountKey: "acct-b", from: file) == nil)

        // A file written by an older build: dropped, because re-syncing is
        // always available and migrating a cache never earns its keep.
        var stale = snapshot(previews: [])
        stale.schema = MailSnapshot.currentSchema - 1
        MailSnapshotStore.save(stale, to: file)
        #expect(MailSnapshotStore.load(accountKey: "acct-a", from: file) == nil)

        // Corrupt bytes, and a path with nothing at it, both mean "no cache".
        try Data("not json".utf8).write(to: file)
        #expect(MailSnapshotStore.load(accountKey: "acct-a", from: file) == nil)
        #expect(MailSnapshotStore.load(accountKey: "acct-a", from: scratchFile()) == nil)
    }

    @Test("Clearing leaves nothing behind")
    func clearRemovesTheFile() throws {
        let file = scratchFile()
        MailSnapshotStore.save(snapshot(previews: [try preview()]), to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))

        MailSnapshotStore.clear(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(MailSnapshotStore.load(accountKey: "acct-a", from: file) == nil)
    }
}

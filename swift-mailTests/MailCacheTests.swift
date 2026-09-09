//
//  MailCacheTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// What the cache has to get right: give back what went in, order a folder the
/// way the server would, follow a message when it moves, and throw itself away
/// rather than hand over something it can't vouch for.
///
/// `MailCache` is a singleton around one connection, so these run serialized
/// against a scratch database rather than the real one.
@Suite(.serialized)
struct MailCacheTests {
    private func openScratchCache(accountKey: String = "acct-a") throws -> (cache: MailCache, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: "cache.sqlite")
        let cache = MailCache.shared
        cache.open(accountKey: accountKey, at: file)
        // The singleton may already be open from an earlier test; clearing gives
        // each one an empty database without reaching for a second connection.
        cache.clear()

        return (cache, file)
    }

    private func preview(
        id: String = "E1",
        receivedAt: String = "2026-09-09T02:15:00Z",
        mailboxes: [String] = ["mb1"],
        seen: Bool = false
    ) throws -> EmailPreview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let mailboxIDs = mailboxes.map { "\"\($0)\": true" }.joined(separator: ",")

        return try decoder.decode(EmailPreview.self, from: Data("""
        {
            "id": "\(id)",
            "threadId": "T-\(id)",
            "subject": "Quarterly invoice",
            "receivedAt": "\(receivedAt)",
            "mailboxIds": { \(mailboxIDs) },
            "keywords": { "$seen": \(seen) },
            "to": [{ "email": "a1b2c3@privaterelay.appleid.com" }],
            "header:X-Delivered-To:asAddresses": [{ "email": "declan@example.com" }]
        }
        """.utf8))
    }

    @Test("A folder comes back newest first")
    func pageIsOrderedNewestFirst() throws {
        let (cache, _) = try openScratchCache()

        cache.store(previews: [
            try preview(id: "old", receivedAt: "2026-09-01T00:00:00Z"),
            try preview(id: "new", receivedAt: "2026-09-09T00:00:00Z"),
            try preview(id: "mid", receivedAt: "2026-09-05T00:00:00Z"),
            try preview(id: "elsewhere", receivedAt: "2026-09-09T12:00:00Z", mailboxes: ["mb2"])
        ])

        // The server sorts by receivedAt descending, and the cache reproduces
        // that from a field it holds rather than mirroring query positions.
        #expect(cache.page(mailboxID: "mb1", limit: 10).map(\.id) == ["new", "mid", "old"])
        #expect(cache.page(mailboxID: "mb2", limit: 10).map(\.id) == ["elsewhere"])
        #expect(cache.page(mailboxID: "mb1", limit: 2).map(\.id) == ["new", "mid"])
        #expect(cache.page(mailboxID: "nothing-here", limit: 10).isEmpty)
    }

    @Test("A restored message keeps everything the tag feature reads")
    func previewSurvivesTheRoundTrip() throws {
        let (cache, _) = try openScratchCache()
        cache.store(previews: [try preview()])

        let restored = try #require(cache.page(mailboxID: "mb1", limit: 10).first)

        #expect(restored.subject == "Quarterly invoice")
        #expect(restored.isUnread)
        #expect(restored.threadId == "T-E1")
        // `deliveredTo` encodes under "header:X-Delivered-To:asAddresses", not a
        // plain property name. Losing it would leave relayed mail untagged on
        // every launch until the first sync landed.
        #expect(MailTag(name: "Work", color: .blue, addresses: ["declan@example.com"]).matches(restored))
    }

    @Test("A moved message leaves the folder it came from")
    func membershipIsRewrittenNotAdded() throws {
        let (cache, _) = try openScratchCache()
        cache.store(previews: [try preview(mailboxes: ["mb1"])])
        #expect(cache.page(mailboxID: "mb1", limit: 10).count == 1)

        // Archiving is the same message in a different folder. A stale row here
        // would leave it showing in both.
        cache.store(previews: [try preview(mailboxes: ["mb2"])])
        #expect(cache.page(mailboxID: "mb1", limit: 10).isEmpty)
        #expect(cache.page(mailboxID: "mb2", limit: 10).count == 1)

        cache.remove(emailIDs: ["E1"])
        #expect(cache.page(mailboxID: "mb2", limit: 10).isEmpty)
    }

    @Test("Cursors, folders and identities survive a relaunch")
    func restorableState() throws {
        let (cache, _) = try openScratchCache()

        cache.setSyncState("2f9e:8821", for: "Email")
        cache.setSyncState("41ab:07", for: "Mailbox")
        cache.setSelectedMailboxID("mb1")
        cache.setMailboxes([
            Mailbox(id: "mb1", name: "Inbox", role: "inbox", parentId: nil, sortOrder: 0, totalEmails: 12, unreadEmails: 3),
            Mailbox(id: "mb2", name: "Archive", role: "archive", parentId: nil, sortOrder: 1, totalEmails: 4, unreadEmails: 0)
        ])
        cache.setIdentities([
            MailIdentity(id: "id1", name: "Declan", email: "declan@example.com", replyTo: nil, bcc: nil, textSignature: nil, htmlSignature: nil)
        ])

        // Without the cursors the first sync of a launch has nothing to diff
        // against and falls back to re-querying the mailbox.
        #expect(cache.syncState(for: "Email") == "2f9e:8821")
        #expect(cache.syncState(for: "Mailbox") == "41ab:07")
        #expect(cache.selectedMailboxID() == "mb1")
        #expect(cache.mailboxes().map(\.id) == ["mb1", "mb2"])
        #expect(cache.mailboxes().first?.unreadEmails == 3)
        #expect(cache.identities().first?.email == "declan@example.com")
    }

    @Test("A cached body is returned whole, and dies with its message")
    func bodyRoundTrip() throws {
        let (cache, _) = try openScratchCache()

        let detail = try JSONDecoder().decode(EmailDetail.self, from: Data("""
        {
            "id": "E1",
            "subject": "Quarterly invoice",
            "textBody": [{ "partId": "1", "type": "text/plain" }],
            "bodyValues": { "1": { "value": "The invoice is attached." } },
            "attachments": [{ "blobId": "B1", "name": "invoice.pdf", "type": "application/pdf", "size": 2048 }]
        }
        """.utf8))

        cache.store(body: detail)
        let restored = try #require(cache.body(for: "E1"))

        #expect(restored.readableBody == "The invoice is attached.")
        #expect(restored.listedAttachments.first?.displayName == "invoice.pdf")
        #expect(cache.body(for: "no-such-message") == nil)

        // A deleted message must not leave its body behind.
        cache.remove(emailIDs: ["E1"])
        #expect(cache.body(for: "E1") == nil)
    }

    @Test("Attachment bytes come back for a blob id that can't be a filename")
    func blobRoundTrip() throws {
        let (cache, file) = try openScratchCache()
        // Blob ids are the server's to choose: this one would escape the cache
        // directory entirely if it were trusted as a path.
        let blobID = "../../etc/passwd"
        let bytes = Data("%PDF-1.7 synthetic".utf8)

        cache.store(blob: bytes, for: blobID)

        #expect(cache.blob(for: blobID) == bytes)
        #expect(cache.blob(for: "never-downloaded") == nil)

        let blobs = file.deletingLastPathComponent().appending(path: "Blobs")
        let names = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        #expect(names.count == 1)
        #expect(names.first?.count == 64)      // a SHA-256 hex digest, not the id
        #expect(names.first?.contains("/") == false)
    }

    @Test("Signing out takes the cached mail with it")
    func clearRemovesEverything() throws {
        let (cache, _) = try openScratchCache()

        cache.store(previews: [try preview()])
        cache.setSyncState("2f9e:8821", for: "Email")
        #expect(cache.page(mailboxID: "mb1", limit: 10).count == 1)

        // The next account must never be handed the previous one's messages.
        cache.clear()
        #expect(cache.page(mailboxID: "mb1", limit: 10).isEmpty)
        #expect(cache.syncState(for: "Email") == nil)
        #expect(cache.mailboxes().isEmpty)
    }
}

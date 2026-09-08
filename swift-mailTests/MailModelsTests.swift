import Foundation
import Testing
@testable import swift_mail

struct MailModelsTests {

    /// The reader decides "is this a draft?" from the message, not from the
    /// selected mailbox: the sidebar writes the new mailbox id a render before
    /// the reload clears the old selection, and a mailbox-derived answer opened
    /// a compose window pre-filled with whatever was previously on screen.
    @Test("Draft-ness comes from the message's own keyword")
    func draftKeywordIdentifiesDrafts() throws {
        let draft = try decodeEmailDetail("""
        { "id": "D1", "keywords": { "$draft": true, "$seen": true } }
        """)
        #expect(draft.isDraft)

        let archived = try decodeEmailDetail("""
        { "id": "A1", "keywords": { "$seen": true } }
        """)
        #expect(!archived.isDraft)

        // No keywords at all is not a draft either.
        #expect(try !decodeEmailDetail("{ \"id\": \"A2\" }").isDraft)
    }

    @Test("Attachment names are reduced to one safe path component")
    func attachmentFileNames() {
        func name(_ raw: String?) -> String {
            MailStore.safeFileName(for: EmailAttachment(blobId: "b", type: nil, name: raw, size: nil, disposition: nil, cid: nil))
        }

        #expect(name("report.pdf") == "report.pdf")
        #expect(name("../../../etc/passwd") == "passwd")
        #expect(name("..") == "attachment")
        #expect(name(".hidden") == "hidden")
        #expect(name(nil) == "Attachment")
        // A blank name never reaches the sanitiser: displayName falls back first.
        #expect(name("  ") == "Attachment")
    }

    @Test("Saving numbers a name that is already taken")
    func downloadNameCollisions() {
        let directory = URL(filePath: "/Users/someone/Downloads")
        let taken: Set<String> = ["report.pdf", "report 2.pdf"]
        let url = MailStore.uniqueURL(in: directory, named: "report.pdf") { taken.contains($0.lastPathComponent) }

        #expect(url.lastPathComponent == "report 3.pdf")
        #expect(MailStore.uniqueURL(in: directory, named: "fresh.pdf") { taken.contains($0.lastPathComponent) }.lastPathComponent == "fresh.pdf")
    }

    @Test("Safe-sender matching is exact, case-insensitive, and additive")
    func safeSenderList() {
        #expect(SafeSenders.domain(of: "dwade@FASTMAIL.com") == "fastmail.com")
        #expect(SafeSenders.domain(of: "not-an-address") == "not-an-address")
        #expect(SafeSenders.domain(of: nil) == nil)

        let list = SafeSenders.adding("Fastmail.com", to: "")

        #expect(list == "fastmail.com")
        #expect(SafeSenders.contains("fastmail.com", in: list))
        #expect(SafeSenders.contains("FASTMAIL.COM", in: list))
        // A lookalike domain must not match by substring.
        #expect(SafeSenders.contains("evil-fastmail.com", in: list) == false)
        #expect(SafeSenders.contains("mail.fastmail.com", in: list) == false)
        // Adding is idempotent and keeps earlier entries.
        #expect(SafeSenders.adding("fastmail.com", to: list) == list)
        #expect(SafeSenders.adding("apple.com", to: list) == "apple.com,fastmail.com")
    }

    /// RFC 8621 4.6: a body part given a `partId` must not also carry
    /// `charset`. Fastmail rejects the whole send with `invalidProperties`.
    @Test("Draft body parts declare a partId and no charset")
    func bodyPartsOmitCharset() throws {
        let identity = MailIdentity(
            id: "i1",
            name: "Declan",
            email: "dwade@fastmail.com",
            replyTo: nil,
            bcc: nil,
            textSignature: nil,
            htmlSignature: nil
        )

        let email = JMAPClient.emailObject(
            draft: ComposeDraft(to: [EmailAddress(email: "someone@example.com")], subject: "Test", markdown: "hello"),
            identity: identity,
            mailboxIDs: ["drafts": true],
            keywords: ["$draft": true]
        )

        let structure = try #require(email["bodyStructure"] as? [String: Any])
        let subParts = try #require(structure["subParts"] as? [[String: Any]])

        #expect(subParts.count == 2)
        #expect(subParts.allSatisfy { $0["partId"] != nil })
        #expect(subParts.allSatisfy { $0["charset"] == nil })
        #expect(email["bodyValues"] != nil)
    }
    private func decodeEmailDetail(_ json: String) throws -> EmailDetail {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EmailDetail.self, from: Data(json.utf8))
    }

    @Test("An explicit attachment disposition is listed even with a cid")
    func attachmentDispositionIsListed() {
        let cidAttachment = EmailAttachment(blobId: "b1", type: "application/pdf", name: "statement.pdf", size: 1024, disposition: "attachment", cid: "abc@host")
        let inlineImage = EmailAttachment(blobId: "b2", type: "image/png", name: "logo.png", size: 200, disposition: "inline", cid: "logo@host")
        let bareCID = EmailAttachment(blobId: "b3", type: "image/png", name: nil, size: 10, disposition: nil, cid: "x@host")

        #expect(cidAttachment.isInline == false)
        #expect(inlineImage.isInline == true)
        #expect(bareCID.isInline == true)
    }

    @Test("listedAttachments filters out inline parts")
    func listedAttachmentsExcludesInline() throws {
        let email = try decodeEmailDetail("""
        {
            "id": "E1",
            "attachments": [
                { "blobId": "b1", "name": "report.pdf", "type": "application/pdf", "size": 5, "disposition": "attachment" },
                { "blobId": "b2", "name": "sig.png", "type": "image/png", "size": 5, "disposition": "inline", "cid": "sig@host" }
            ]
        }
        """)

        #expect(email.listedAttachments.map(\.displayName) == ["report.pdf"])
    }

    @Test("Remote content is detected from http(s) references in the HTML body")
    func remoteContentDetection() throws {
        let remote = try decodeEmailDetail("""
        {
            "id": "E2",
            "htmlBody": [{ "partId": "1", "type": "text/html" }],
            "bodyValues": { "1": { "value": "<p>Hi</p><img src=\\"https://tracker.example/pixel.gif\\">" } }
        }
        """)

        let local = try decodeEmailDetail("""
        {
            "id": "E3",
            "htmlBody": [{ "partId": "1", "type": "text/html" }],
            "bodyValues": { "1": { "value": "<p>Hi</p><img src=\\"cid:logo\\">" } }
        }
        """)

        #expect(remote.htmlBodyLoadsRemoteContent == true)
        #expect(local.htmlBodyLoadsRemoteContent == false)
    }

    /// The reader entity-decodes the body before handing it to the web view, so
    /// the detector has to look at the same decoded text. A real message with 70
    /// images and 330 `&quot;` entities was reported as having no remote content
    /// — images blocked, no banner to unblock them.
    @Test("Entity-encoded attribute quotes still count as remote content")
    func entityEncodedRemoteContent() throws {
        let encoded = try decodeEmailDetail("""
        {
            "id": "E4",
            "htmlBody": [{ "partId": "1", "type": "text/html" }],
            "bodyValues": { "1": { "value": "<img src=&quot;https://tracker.example/pixel.gif&quot;>" } }
        }
        """)

        #expect(encoded.htmlBodyLoadsRemoteContent == true)
    }

    /// The web view resolves these to https, where the content blocker stops
    /// them, so the banner has to be offered for them too.
    @Test("Protocol-relative URLs count as remote content")
    func protocolRelativeRemoteContent() throws {
        func detail(_ body: String) throws -> EmailDetail {
            try decodeEmailDetail("""
            {
                "id": "E5",
                "htmlBody": [{ "partId": "1", "type": "text/html" }],
                "bodyValues": { "1": { "value": "\(body)" } }
            }
            """)
        }

        #expect(try detail("<img src=\\\"//cdn.example/a.png\\\">").htmlBodyLoadsRemoteContent)
        #expect(try detail("<div style=\\\"background:url(//cdn.example/b.png)\\\">").htmlBodyLoadsRemoteContent)
        // Root-relative and inline data stay local.
        #expect(try !detail("<img src=\\\"/local/a.png\\\">").htmlBodyLoadsRemoteContent)
        #expect(try !detail("<img src=\\\"data:image/png;base64,AAAA\\\">").htmlBodyLoadsRemoteContent)
    }

    @Test("editDraft seeds recipients, subject and body from the source draft")
    func editDraftSeeding() throws {
        let email = try decodeEmailDetail("""
        {
            "id": "DRAFT-1",
            "to": [{ "email": "a@x.com" }],
            "cc": [{ "email": "b@x.com" }],
            "subject": "Half-written",
            "textBody": [{ "partId": "1", "type": "text/plain" }],
            "bodyValues": { "1": { "value": "body text" } }
        }
        """)

        let draft = ComposeDraft.editDraft(from: email, identity: nil)

        #expect(draft.mode == .editDraft)
        #expect(draft.sourceDraftID == "DRAFT-1")
        #expect(draft.to.map(\.email) == ["a@x.com"])
        #expect(draft.cc.map(\.email) == ["b@x.com"])
        #expect(draft.showsCarbonCopy == true)
        #expect(draft.subject == "Half-written")
        #expect(draft.markdown == "body text")
    }

    @Test("editDraft produces a stable window id for the same source draft")
    func editDraftDeterministicID() throws {
        let email = try decodeEmailDetail("{ \"id\": \"DRAFT-9\" }")

        let first = ComposeDraft.editDraft(from: email, identity: nil)
        let second = ComposeDraft.editDraft(from: email, identity: nil)

        #expect(first.id == second.id)
    }
}

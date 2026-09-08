import Foundation
import Testing
@testable import swift_mail

struct MailModelsTests {

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

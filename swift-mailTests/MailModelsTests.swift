import Foundation
import Testing
@testable import swift_mail

struct MailModelsTests {
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

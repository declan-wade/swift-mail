import Foundation
import Testing
@testable import swift_mail

struct ForwardFormatTests {
    private func email(_ json: String) throws -> EmailDetail {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EmailDetail.self, from: Data(json.utf8))
    }

    private let source = """
    {
        "id": "M1",
        "subject": "Quarterly numbers",
        "from": [{ "name": "Ana", "email": "ana@example.com" }],
        "htmlBody": [{ "partId": "1", "type": "text/html" }],
        "textBody": [{ "partId": "2", "type": "text/plain" }],
        "bodyValues": {
            "1": { "value": "<table><tr><td>Styled &quot;table&quot;</td></tr></table><img src=\\"cid:chart-1\\">" },
            "2": { "value": "Plain fallback" }
        },
        "attachments": [
            { "blobId": "B-inline", "type": "image/png", "name": "chart.png", "size": 120, "disposition": "inline", "cid": "chart-1" },
            { "blobId": "B-file", "type": "application/pdf", "name": "report.pdf", "size": 900, "disposition": "attachment" }
        ]
    }
    """

    @Test("A Markdown forward flattens the body and carries no HTML")
    func markdownForwardFlattens() throws {
        let draft = ComposeDraft.forward(try email(source), identity: nil)

        #expect(draft.forwardedHTML == nil)
        // The plain-text body is what gets quoted.
        #expect(draft.markdown.contains("Plain fallback"))
        #expect(!draft.markdown.contains("<table>"))
    }

    @Test("Both forward formats carry the real attachments")
    func bothFormatsCarryAttachments() throws {
        let markdown = ComposeDraft.forward(try email(source), identity: nil)
        let html = ComposeDraft.forward(try email(source), identity: nil, preservingHTML: true)

        #expect(markdown.listedAttachments.map(\.blobId) == ["B-file"])
        #expect(html.listedAttachments.map(\.blobId) == ["B-file"])

        // Only the HTML forward keeps the inline part: Markdown has flattened
        // away the `cid:` reference that gave it a purpose, so attaching it
        // would just add a stray signature image.
        #expect(html.attachments.contains { $0.isInline })
        #expect(!markdown.attachments.contains { $0.isInline })
    }

    @Test("An HTML forward keeps the original markup verbatim")
    func htmlForwardPreservesMarkup() throws {
        let draft = ComposeDraft.forward(try email(source), identity: nil, preservingHTML: true)
        let html = try #require(draft.forwardedHTML)

        #expect(html.contains("<table>"))
        // Entity-decoded the same way the reader decodes it.
        #expect(html.contains("Styled \"table\""))
        #expect(html.contains("cid:chart-1"))
        // The forward header is announced in the HTML, not left to Markdown.
        #expect(html.contains("Forwarded message"))
        #expect(!draft.markdown.contains("Forwarded message"))
    }

    @Test("An HTML forward carries the inline part its body references")
    func htmlForwardCarriesInlineParts() throws {
        let draft = ComposeDraft.forward(try email(source), identity: nil, preservingHTML: true)

        let inline = draft.attachments.filter(\.isInline)
        #expect(inline.count == 1)
        #expect(inline.first?.contentID == "chart-1")
        #expect(inline.first?.blobId == "B-inline")

        // Real attachments come along too, and are the only ones the compose
        // window lists — an inline carrier is part of the body, not a file.
        #expect(draft.listedAttachments.map(\.blobId) == ["B-file"])
    }

    @Test("Content-IDs match whether or not the sender wrapped them in brackets")
    func contentIDNormalisation() {
        #expect(MailStore.normalizedContentID("<chart-1>") == "chart-1")
        #expect(MailStore.normalizedContentID(" Chart-1 ") == "chart-1")
        #expect(MailStore.normalizedContentID("chart-1") == "chart-1")
    }
}

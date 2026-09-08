//
//  JMAPSessionTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

struct JMAPSessionTests {

    @Test("downloadUrl template expands and percent-encodes every value")
    func downloadURLExpansion() throws {
        let json = """
        {
            "apiUrl": "https://api.fastmail.com/jmap/api/",
            "downloadUrl": "https://api.fastmail.com/jmap/download/{accountId}/{blobId}/{name}?type={type}",
            "primaryAccounts": {}
        }
        """

        let session = try JSONDecoder().decode(JMAPSession.self, from: Data(json.utf8))
        let url = try #require(
            session.downloadURL(accountID: "u1", blobID: "b1", type: "application/pdf", name: "../my report.pdf")
        )

        #expect(url.absoluteString == "https://api.fastmail.com/jmap/download/u1/b1/..%2Fmy%20report.pdf?type=application%2Fpdf")
        // One path segment, no traversal.
        #expect(url.pathComponents == ["/", "jmap", "download", "u1", "b1", "../my report.pdf"])
    }

    @Test("A session without downloadUrl yields no download URL")
    func downloadURLMissing() throws {
        let json = """
        { "apiUrl": "https://api.fastmail.com/jmap/api/", "primaryAccounts": {} }
        """

        let session = try JSONDecoder().decode(JMAPSession.self, from: Data(json.utf8))

        #expect(session.downloadURL(accountID: "u1", blobID: "b1", type: nil, name: nil) == nil)
    }
    private func makeSession(eventSourceURL: URL?) -> JMAPSession {
        let eventSourceField = eventSourceURL.map { "\"\($0.absoluteString)\"" } ?? "null"
        let json = """
        {
            "apiUrl": "https://example.com/api",
            "eventSourceUrl": \(eventSourceField),
            "accounts": {},
            "primaryAccounts": {}
        }
        """

        return try! JSONDecoder().decode(JMAPSession.self, from: Data(json.utf8))
    }

    @Test("A template-style event source URL has its placeholders substituted")
    func templatePlaceholdersAreSubstituted() {
        // `URL(string:)` percent-encodes `{`/`}` the moment `makeSession`
        // decodes this from JSON — exactly as it would decoding a real JMAP
        // server's session response — so by the time `eventSourceURL(types:)`
        // sees it, the placeholders already read `%7Btypes%7D`. That's the
        // form to test against; the literal-brace form used to be the only
        // one checked and is unreachable through the real decode path.
        let session = makeSession(eventSourceURL: URL(string: "https://example.com/events/{types}/{closeafter}"))
        let url = session.eventSourceURL(types: ["Email", "Mailbox"], closeAfter: 60)

        #expect(url?.absoluteString == "https://example.com/events/Email,Mailbox/60")
    }

    @Test("An RFC 8620 template with a ping placeholder still resolves")
    func templateWithPingPlaceholder() {
        let session = makeSession(eventSourceURL: URL(string: "https://example.com/events/{types}/{closeafter}/{ping}"))
        let url = session.eventSourceURL(types: ["Email"], closeAfter: 300)

        #expect(url?.absoluteString == "https://example.com/events/Email/300/0")
    }

    @Test("A plain event source URL gets query items appended instead")
    func plainURLGetsQueryItemsAppended() {
        let session = makeSession(eventSourceURL: URL(string: "https://example.com/events"))
        let url = session.eventSourceURL(types: ["Email"], closeAfter: 300)

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        #expect(queryItems.contains(URLQueryItem(name: "types", value: "Email")))
        #expect(queryItems.contains(URLQueryItem(name: "closeafter", value: "300")))
    }

    @Test("No event source URL means no event source")
    func missingEventSourceURLReturnsNil() {
        let session = makeSession(eventSourceURL: nil)
        #expect(session.eventSourceURL(types: ["Email"]) == nil)
    }
}

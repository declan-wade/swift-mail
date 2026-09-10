import Foundation
import Testing
@testable import swift_mail

/// The parts of masked email that are ours rather than the server's: decoding
/// a vendor payload, finding an address again, and ordering the list.
struct MaskedEmailTests {
    private func decode(_ json: String) throws -> [MaskedEmail] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode([MaskedEmail].self, from: Data(json.utf8))
    }

    @Test("Fastmail's `description` lands on `note`")
    func decodesDescriptionAsNote() throws {
        let masked = try decode("""
        [{"id": "m1", "email": "a@b.com", "state": "enabled", "description": "Netflix",
          "forDomain": "netflix.com", "url": null, "createdAt": "2026-01-02T03:04:05Z",
          "lastMessageAt": null, "createdBy": "swift-mail"}]
        """)

        #expect(masked.first?.note == "Netflix")
        #expect(masked.first?.forDomain == "netflix.com")
        #expect(masked.first?.lastMessageAt == nil)
    }

    @Test("An unrecognised state doesn't take the rest of the list down with it")
    func unknownStateDecodes() throws {
        let masked = try decode("""
        [{"id": "m1", "email": "a@b.com", "state": "quarantined"},
         {"id": "m2", "email": "c@d.com", "state": "enabled"}]
        """)

        #expect(masked.count == 2)
        #expect(masked.first?.state == .unknown)
        #expect(masked.last?.state == .enabled)
    }

    @Test("Search covers the address, the note and the site")
    func searchMatchesEveryLabel() throws {
        let masked = try decode("""
        [{"id": "m1", "email": "wandering.turtle@fastmail.com", "state": "enabled",
          "description": "Streaming", "forDomain": "netflix.com"}]
        """).first!

        #expect(masked.matches("turtle"))
        #expect(masked.matches("STREAMING"))
        #expect(masked.matches("netflix"))
        #expect(!masked.matches("spotify"))
        // An empty query is a list, not a filter.
        #expect(masked.matches("  "))
    }

    @Test("The name falls back from note to site to the address itself")
    func displayNameFallsBack() throws {
        let masked = try decode("""
        [{"id": "m1", "email": "a@b.com", "state": "enabled", "description": "", "forDomain": "shop.example"},
         {"id": "m2", "email": "c@d.com", "state": "enabled"}]
        """)

        #expect(masked.first?.displayName == "shop.example")
        #expect(masked.last?.displayName == "c@d.com")
    }

    @Test("Recently used sorts above older, and unused falls back to its creation date")
    func inUseOrderPrefersRecentActivity() throws {
        let masked = try decode("""
        [{"id": "old", "email": "old@x.com", "state": "enabled", "lastMessageAt": "2026-01-01T00:00:00Z"},
         {"id": "new", "email": "new@x.com", "state": "enabled", "lastMessageAt": "2026-06-01T00:00:00Z"},
         {"id": "unused", "email": "unused@x.com", "state": "pending", "createdAt": "2026-03-01T00:00:00Z"}]
        """).sorted(by: MaskedEmail.inUseOrder)

        #expect(masked.map(\.id) == ["new", "unused", "old"])
    }
}

//
//  MailTagTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// What a tag claims as its mail. Everything downstream — the label on a row,
/// which messages a narrowed folder shows, what a sweep would move — is this
/// one predicate, so it has to be right about wildcards and about the
/// addresses it must *not* claim.
struct MailTagTests {
    private let work = MailTag(name: "Work", color: .blue, addresses: ["declan@example.com"])
    private let wildcard = MailTag(name: "Domain", color: .green, addresses: ["*@example.com"])

    private func preview(
        from: String = "stranger@elsewhere.test",
        to: [String] = [],
        cc: [String] = [],
        deliveredTo: [String] = []
    ) throws -> EmailPreview {
        func addresses(_ list: [String]) -> String {
            list.map { #"{ "email": "\#($0)" }"# }.joined(separator: ",")
        }

        return try JSONDecoder().decode(EmailPreview.self, from: Data("""
        {
            "id": "E1",
            "from": [\(addresses([from]))],
            "to": [\(addresses(to))],
            "cc": [\(addresses(cc))],
            "header:X-Delivered-To:asAddresses": [\(addresses(deliveredTo))]
        }
        """.utf8))
    }

    @Test("A tag claims mail to its alias, copied to it, or sent from it")
    func matchesEveryCorrespondentField() throws {
        #expect(work.matches(try preview(to: ["declan@example.com"])))
        #expect(work.matches(try preview(cc: ["declan@example.com"])))
        // Sent and Drafts: the alias is the sender, the recipients are theirs.
        #expect(work.matches(try preview(from: "declan@example.com", to: ["someone@elsewhere.test"])))
        // Case is the server's to choose, not a reason to miss a match.
        #expect(work.matches(try preview(to: ["Declan@Example.COM"])))
    }

    @Test("Relayed mail is claimed by the address it was delivered to")
    func matchesRelayedMailByDeliveryHeader() throws {
        // Hide My Email: the visible recipient is Apple's relay, and the only
        // mention of the user's own alias is the delivery header Fastmail
        // stamps on the way in.
        let relayed = try preview(
            from: "shop@store.test",
            to: ["a1b2c3@privaterelay.appleid.com"],
            deliveredTo: ["declan@example.com"]
        )

        #expect(work.matches(relayed))
        // The relay's own address still belongs to nobody.
        #expect(!MailTag(name: "Other", color: .pink, addresses: ["someone@example.org"]).matches(relayed))
    }

    @Test("The server query looks in the delivery header too")
    func queryIncludesDeliveryHeader() throws {
        let condition = try #require(work.jmapCondition)
        let conditions = try #require(condition["conditions"] as? [[String: Any]])
        let header = try #require(conditions.compactMap { $0["header"] as? [String] }.first)

        // Narrowing to a tag has to find the same relayed mail the label does,
        // or a message reads "Work" in the unified list and vanishes in Work.
        #expect(header == ["X-Delivered-To", "declan@example.com"])
    }

    @Test("A tag claims nothing that isn't its alias")
    func ignoresOtherAddresses() throws {
        #expect(!work.matches(try preview(to: ["someone@elsewhere.test"])))
        // A prefix of the alias is a different address.
        #expect(!work.matches(try preview(to: ["decl@example.com"])))
        #expect(!work.matches(try preview()))
    }

    @Test("A wildcard alias covers its domain and stops at the domain boundary")
    func wildcardMatchesByDomain() throws {
        #expect(wildcard.matches(try preview(to: ["anything@example.com"])))
        #expect(wildcard.matches(try preview(to: ["billing+tag@example.com"])))
        // The lookalike a plain suffix test would wrongly hand over.
        #expect(!wildcard.matches(try preview(to: ["bob@notexample.com"])))
        #expect(!wildcard.matches(try preview(to: ["example.com@elsewhere.test"])))
    }

    @Test("Between two tags that both name the address, the first listed wins")
    func firstTagWins() throws {
        let other = MailTag(name: "Other", color: .teal, addresses: ["declan@example.com"])
        let tags = [work, other]
        let email = try preview(to: ["declan@example.com"])

        #expect(tags.tag(for: email)?.name == "Work")
        #expect(Array(tags.reversed()).tag(for: email)?.name == "Other")
        #expect(tags.tag(for: try preview(to: ["nobody@elsewhere.test"])) == nil)
        #expect([MailTag]().tag(for: email) == nil)
    }

    @Test("A named address beats a wildcard covering it, so it can be reassigned")
    func namedAddressBeatsWildcard() throws {
        // The whole bug this guards: with order alone deciding, an address
        // under someone else's wildcard could never be moved — the new tag
        // recorded it and the wildcard went on claiming it, so the change
        // looked like it silently failed. `wildcard` is listed first here and
        // still loses, because `legacy` names the address itself.
        let legacy = MailTag(name: "Legacy", color: .red, addresses: ["declan@example.com"])
        let tags = [wildcard, legacy]

        #expect(tags.tag(for: try preview(to: ["declan@example.com"]))?.name == "Legacy")
        #expect(tags.tag(forAddress: "declan@example.com")?.name == "Legacy")
        #expect(tags.tag(forAddress: "DECLAN@example.com")?.name == "Legacy")

        // An address the wildcard covers but nobody wrote down still belongs
        // to the wildcard — precedence, not exclusion.
        #expect(tags.tag(forAddress: "someone.else@example.com")?.name == "Domain")
        #expect(tags.tag(for: try preview(to: ["someone.else@example.com"]))?.name == "Domain")
        #expect(tags.tag(forAddress: "nobody@elsewhere.test") == nil)
    }

    @Test("A wildcard entry is never mistaken for a named address")
    func wildcardIsNotAnExactEntry() {
        #expect(!wildcard.containsExactly(address: "*@example.com"))
        #expect(!wildcard.containsExactly(address: "declan@example.com"))
        #expect(work.containsExactly(address: "declan@example.com"))
        #expect(work.containsExactly(address: "Declan@Example.com"))
    }

    @Test("A tag with no aliases narrows nothing")
    func emptyTagHasNoCondition() {
        #expect(MailTag(name: "Empty", color: .red).jmapCondition == nil)
    }

    @Test("The server query asks for the domain, never the literal wildcard")
    func wildcardQueriesItsDomain() throws {
        let condition = try #require(wildcard.jmapCondition)
        let conditions = try #require(condition["conditions"] as? [[String: Any]])

        #expect(condition["operator"] as? String == "OR")
        // Every header a correspondent can appear in, or the narrowed Sent
        // folder comes back empty.
        #expect(Set(conditions.flatMap(\.keys)) == ["from", "to", "cc", "header"])
        #expect(Set(conditions.compactMap { $0.values.first as? String }) == ["@example.com"])
    }

    @Test("An ordinary alias is queried whole")
    func plainAliasQueriesTheAddress() throws {
        let condition = try #require(work.jmapCondition)
        let conditions = try #require(condition["conditions"] as? [[String: Any]])

        #expect(Set(conditions.compactMap { $0.values.first as? String }) == ["declan@example.com"])
    }

    @Test("Tags survive a relaunch, and a corrupt list starts untagged")
    func storageRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "tags-\(UUID().uuidString)"))

        #expect(TagPreferences.load(from: defaults).isEmpty)

        TagPreferences.save([work, wildcard], to: defaults)
        #expect(TagPreferences.load(from: defaults) == [work, wildcard])

        TagPreferences.saveActiveID(work.id, to: defaults)
        #expect(TagPreferences.loadActiveID(from: defaults) == work.id)
        TagPreferences.saveActiveID(nil, to: defaults)
        #expect(TagPreferences.loadActiveID(from: defaults) == nil)

        // Unreadable tags mean the untagged app, never a failed launch.
        defaults.set(Data("not json".utf8), forKey: TagPreferences.tagsKey)
        #expect(TagPreferences.load(from: defaults).isEmpty)
    }

    @Test("A new tag arrives named and coloured differently from the last")
    func suggestionsDontRepeat() {
        #expect(MailTag.suggestedName(existing: []) == "Personal")

        let personal = MailTag(name: MailTag.suggestedName(existing: []), color: MailTag.suggestedColor(existing: []))
        #expect(MailTag.suggestedName(existing: [personal]) == "Work")

        let second = MailTag(name: "Work", color: MailTag.suggestedColor(existing: [personal]))
        #expect(second.color != personal.color)
        #expect(MailTag.suggestedName(existing: [personal, second]) == "Tag 3")
    }

    // MARK: - Addresses the pane will accept

    @Test("An address is normalised to its stored form")
    func normalisesAddresses() {
        #expect(MailTag.normalizedAddress("  DWade@Outlook.com.au ") == "dwade@outlook.com.au")
        #expect(MailTag.normalizedAddress("gundamire@gmail.com") == "gundamire@gmail.com")
        // Both wildcard spellings survive: the matcher understands each.
        #expect(MailTag.normalizedAddress("*@codexgroup.com.au") == "*@codexgroup.com.au")
        #expect(MailTag.normalizedAddress("@codexgroup.com.au") == "@codexgroup.com.au")
    }

    @Test("Anything that couldn't match a message is refused")
    func refusesNonAddresses() {
        for text in ["", "   ", "dwade", "@", "dwade@", "@localhost", "dwade@x", "a b@example.com", "dwade@example."] {
            #expect(MailTag.normalizedAddress(text) == nil, "accepted \(text)")
        }
    }

    @Test("A hand-added external address tags its mail like any identity would")
    func externalAddressMatches() throws {
        let address = try #require(MailTag.normalizedAddress("dwade@outlook.com.au"))
        let tag = MailTag(name: "Personal", color: .blue, addresses: [address])

        // Mail collected from an external account keeps the headers that
        // account received it with, so the address is in `to` — there is no
        // Fastmail delivery header naming it.
        #expect(tag.matches(try preview(to: ["DWade@outlook.com.au"])))
        #expect(!tag.matches(try preview(to: ["someone@elsewhere.test"])))
    }
}

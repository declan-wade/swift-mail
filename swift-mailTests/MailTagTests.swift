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

    private func preview(from: String = "stranger@elsewhere.test", to: [String] = [], cc: [String] = []) throws -> EmailPreview {
        func addresses(_ list: [String]) -> String {
            list.map { #"{ "email": "\#($0)" }"# }.joined(separator: ",")
        }

        return try JSONDecoder().decode(EmailPreview.self, from: Data("""
        {
            "id": "E1",
            "from": [\(addresses([from]))],
            "to": [\(addresses(to))],
            "cc": [\(addresses(cc))]
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

    @Test("A message reaching two tags takes the first one listed")
    func firstTagWins() throws {
        let tags = [work, wildcard]
        let email = try preview(to: ["declan@example.com"])

        #expect(tags.tag(for: email)?.name == "Work")
        #expect(Array(tags.reversed()).tag(for: email)?.name == "Domain")
        #expect(tags.tag(for: try preview(to: ["nobody@elsewhere.test"])) == nil)
        #expect([MailTag]().tag(for: email) == nil)
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
        #expect(Set(conditions.flatMap(\.keys)) == ["from", "to", "cc"])
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
}

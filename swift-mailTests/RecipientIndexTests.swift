//
//  RecipientIndexTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

struct RecipientIndexTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 60 * 60)
    }

    private func recipient(_ email: String, _ name: String?, sends: Int, daysAgo days: Double) -> Recipient {
        Recipient(email: email, name: name, sends: sends, lastSentAt: daysAgo(days))
    }

    // MARK: - Matching

    @Test("A prefix of the address or of any name word matches")
    func matchesPrefixes() {
        let declan = recipient("declan@example.com", "Declan Wade", sends: 1, daysAgo: 1)

        #expect(RecipientIndex.matches(declan, query: "dec"))
        #expect(RecipientIndex.matches(declan, query: "Declan"))
        // A surname is a prefix of a word, not of the whole name.
        #expect(RecipientIndex.matches(declan, query: "wade"))
        #expect(RecipientIndex.matches(declan, query: "DECLAN@EX"))
        #expect(RecipientIndex.matches(declan, query: "declan@example.com"))
    }

    @Test("Matching is prefixes only, so a few letters don't match everyone")
    func rejectsSubstrings() {
        let declan = recipient("declan@example.com", "Declan Wade", sends: 1, daysAgo: 1)

        // "ade" sits inside both "Wade" and the address, and matches neither.
        #expect(!RecipientIndex.matches(declan, query: "ade"))
        #expect(!RecipientIndex.matches(declan, query: "example"))
        #expect(!RecipientIndex.matches(declan, query: "ecla"))
        #expect(!RecipientIndex.matches(declan, query: ""))
        #expect(!RecipientIndex.matches(declan, query: "   "))
    }

    @Test("Once an @ is typed, only the address is being asked about")
    func addressOnlyOnceAtIsTyped() {
        let declan = recipient("declan@example.com", "Wade Consulting", sends: 1, daysAgo: 1)

        #expect(RecipientIndex.matches(declan, query: "declan@"))
        // The name starts with "wade", but "wade@" is a question about an
        // address, and this isn't that address.
        #expect(!RecipientIndex.matches(declan, query: "wade@"))
    }

    @Test("An address with no name still matches on the address")
    func matchesNamelessRecipients() {
        let bare = recipient("accounts@supplier.com", nil, sends: 3, daysAgo: 5)

        #expect(RecipientIndex.matches(bare, query: "acc"))
        #expect(!RecipientIndex.matches(bare, query: "supplier"))
    }

    // MARK: - Ranking

    @Test("Recent correspondence outranks a bigger but stale history")
    func agesFrequency() {
        // Two years ago and fifty messages, against last week and three.
        let stale = recipient("old@example.com", "Old Colleague", sends: 50, daysAgo: 730)
        let fresh = recipient("new@example.com", "New Colleague", sends: 3, daysAgo: 7)

        #expect(RecipientIndex.score(fresh, now: now) > RecipientIndex.score(stale, now: now))

        let ranked = RecipientIndex.completions(for: "new", in: [stale, fresh], now: now)
        #expect(ranked == ["New Colleague <new@example.com>"])
    }

    @Test("At equal recency, frequency decides")
    func frequencyBreaksTies() {
        let often = recipient("often@example.com", "Often Ann", sends: 20, daysAgo: 3)
        let once = recipient("once@example.com", "Once Otto", sends: 1, daysAgo: 3)

        let ranked = RecipientIndex.completions(for: "o", in: [once, often], now: now)

        #expect(ranked.first == "Often Ann <often@example.com>")
        #expect(ranked.count == 2)
    }

    @Test("One half-life halves the weight of a history")
    func halfLifeHalvesTheScore() {
        let fresh = recipient("a@example.com", nil, sends: 8, daysAgo: 0)
        let aged = recipient("b@example.com", nil, sends: 8, daysAgo: RecipientIndex.halfLife / 86_400)

        #expect(abs(RecipientIndex.score(aged, now: now) - RecipientIndex.score(fresh, now: now) / 2) < 0.001)
    }

    @Test("Completions come back as the round-trippable entry form, and are capped")
    func formatsAndLimits() {
        let many = (0..<25).map { recipient("person\($0)@example.com", "Person \($0)", sends: 30 - $0, daysAgo: 1) }

        let ranked = RecipientIndex.completions(for: "person", in: many, now: now, limit: 10)

        #expect(ranked.count == 10)
        #expect(ranked.first == "Person 0 <person0@example.com>")
        // Every completion has to parse back into the address it came from,
        // because that round trip is how the token field turns it into a token.
        #expect(ranked.allSatisfy { EmailAddress(entry: $0) != nil })
        #expect(EmailAddress(entry: ranked[0])?.email == "person0@example.com")
    }

    @Test("Nothing typed, nothing suggested")
    func emptyQueryOffersNothing() {
        let declan = recipient("declan@example.com", "Declan Wade", sends: 9, daysAgo: 1)

        #expect(RecipientIndex.completions(for: "", in: [declan], now: now).isEmpty)
        #expect(RecipientIndex.completions(for: " ", in: [declan], now: now).isEmpty)
    }

    // MARK: - Folding

    @Test("Counts accumulate per address, case-insensitively")
    func foldsCounts() throws {
        var tally: [String: Recipient] = [:]

        RecipientIndex.folding(
            [EmailAddress(name: "Declan Wade", email: "Declan@Example.com")],
            sentAt: daysAgo(10),
            into: &tally
        )
        RecipientIndex.folding(
            [EmailAddress(name: nil, email: "declan@example.com")],
            sentAt: daysAgo(2),
            into: &tally
        )

        #expect(tally.count == 1)
        let declan = try #require(tally["declan@example.com"])
        #expect(declan.sends == 2)
        #expect(declan.lastSentAt == daysAgo(2))
        // The later message carried no name, which is no reason to forget the
        // one already known.
        #expect(declan.name == "Declan Wade")
    }

    @Test("The most recent name wins")
    func keepsNewestName() {
        var tally: [String: Recipient] = [:]

        RecipientIndex.folding(
            [EmailAddress(name: "D. Wade", email: "declan@example.com")],
            sentAt: daysAgo(30),
            into: &tally
        )
        RecipientIndex.folding(
            [EmailAddress(name: "Declan Wade", email: "declan@example.com")],
            sentAt: daysAgo(1),
            into: &tally
        )

        #expect(tally["declan@example.com"]?.name == "Declan Wade")

        // An older message folded in afterwards doesn't overwrite the newer
        // name, which is what makes the pass order-independent.
        RecipientIndex.folding(
            [EmailAddress(name: "Ancient Name", email: "declan@example.com")],
            sentAt: daysAgo(400),
            into: &tally
        )
        #expect(tally["declan@example.com"]?.name == "Declan Wade")
        #expect(tally["declan@example.com"]?.lastSentAt == daysAgo(1))
    }

    @Test("Cc counts as someone written to; a blank address doesn't count at all")
    func foldsCcAndSkipsEmpty() {
        var tally: [String: Recipient] = [:]

        RecipientIndex.folding(
            [
                EmailAddress(name: "To Person", email: "to@example.com"),
                EmailAddress(name: "Cc Person", email: "cc@example.com"),
                EmailAddress(name: "Blank", email: "   ")
            ],
            sentAt: daysAgo(1),
            into: &tally
        )

        #expect(tally.count == 2)
        #expect(tally["to@example.com"]?.sends == 1)
        #expect(tally["cc@example.com"]?.sends == 1)
    }
}

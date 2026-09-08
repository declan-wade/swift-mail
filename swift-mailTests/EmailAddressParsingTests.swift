//
//  EmailAddressParsingTests.swift
//  swift-mailTests
//

import Testing
@testable import swift_mail

struct EmailAddressParsingTests {
    @Test("A comma inside a quoted display name does not split the entry")
    func quotedCommaDoesNotSplit() {
        let addresses = EmailAddress.parseList("\"Doe, Jane\" <jane@x.com>, bob@y.com")

        #expect(addresses.count == 2)
        #expect(addresses.first?.email == "jane@x.com")
        #expect(addresses.first?.name == "Doe, Jane")
        #expect(addresses.last?.email == "bob@y.com")
    }

    @Test("A semicolon separates entries the same as a comma")
    func semicolonSeparates() {
        let addresses = EmailAddress.parseList("a@x.com; b@y.com")
        #expect(addresses.map(\.email) == ["a@x.com", "b@y.com"])
    }

    @Test("A bare address with no display name parses")
    func bareAddress() {
        let addresses = EmailAddress.parseList("a@x.com")
        #expect(addresses.count == 1)
        #expect(addresses.first?.name == nil)
    }

    @Test("Empty and whitespace-only entries are dropped")
    func emptyEntriesAreDropped() {
        let addresses = EmailAddress.parseList("a@x.com, , b@y.com")
        #expect(addresses.map(\.email) == ["a@x.com", "b@y.com"])
    }
}

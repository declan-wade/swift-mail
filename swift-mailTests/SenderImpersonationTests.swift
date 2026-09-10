//
//  SenderImpersonationTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

struct SenderImpersonationTests {

    private func brand(_ name: String?, _ address: String?) -> String? {
        SenderImpersonation.impersonatedBrand(displayName: name, address: address)?.name
    }

    @Test("The classic brand-domain mismatches are flagged")
    func flagsImpersonation() {
        // The real message: the name says myGov, the envelope says prosa.ai.
        #expect(brand("myGov", "source@prosa.ai") == "myGov")
        #expect(brand("myGov", "no-reply@my-gov.com") == "myGov")
        #expect(brand("My Gov", "no-reply@my-gov.com") == "myGov")
        #expect(brand("ANZ", "alerts@anzsecurityemail.com") == "ANZ")
        #expect(brand("ANZ Internet Banking", "alerts@anz-secure.net") == "ANZ")

        // Punctuation and case are normalised away, so neither can be used to
        // dodge the table.
        #expect(brand("m-y-G-o-v", "x@prosa.ai") == "myGov")
        #expect(brand("PAYPAL", "service@paypal-verify.com") == "PayPal")
    }

    @Test("Mail that really is from the brand is left alone")
    func allowsGenuineSenders() {
        #expect(brand("myGov", "noreply@my.gov.au") == nil)
        #expect(brand("Australian Taxation Office", "noreply@ato.gov.au") == nil)
        #expect(brand("ANZ", "alerts@anz.com.au") == nil)
        // A subdomain is still the brand's own domain.
        #expect(brand("ANZ", "alerts@e.anz.com.au") == nil)
        #expect(brand("Apple", "no_reply@email.apple.com") == nil)
        #expect(brand("Australia Post", "track@auspost.com.au") == nil)
    }

    @Test("A domain that merely contains the brand isn't the brand")
    func requiresRegistrableDomainMatch() {
        // The whole point of matching the registrable domain rather than a
        // substring: these read as the brand and are not the brand.
        #expect(brand("ANZ", "x@anz.com.au.phish.example") == "ANZ")
        #expect(brand("myGov", "x@mygov.com") == "myGov")
        #expect(brand("Apple", "x@notapple.com") == "Apple")
    }

    @Test("Senders the table has never heard of stay silent")
    func ignoresUnknownSenders() {
        #expect(brand("Reebelo Australia", "hello@reebelo.com.au") == nil)
        #expect(brand("HackMD Team", "hello@newsletter.hackmd.io") == nil)
        #expect(brand(nil, "someone@example.com") == nil)
        #expect(brand("", "someone@example.com") == nil)
        #expect(brand("Revolut", "no-reply@revolut.com") == nil)
    }

    @Test("Names that merely contain a brand's letters don't trip it")
    func avoidsSubstringFalsePositives() {
        // The prefix rule is why "Pineapple" mustn't read as Apple, and the
        // whole-word rule is why "Anzac" mustn't read as ANZ.
        #expect(brand("Pineapple Express", "orders@pineapple.example") == nil)
        #expect(brand("Anzac Day Committee", "info@anzacday.org.au") == nil)
        #expect(brand("Nabil Hassan", "nabil@example.com") == nil)
        #expect(brand("Government Grants Weekly", "news@grants.example") == nil)
        // A longer alias is still allowed to start the name.
        #expect(brand("MyGov Australia", "x@prosa.ai") == "myGov")
    }

    @Test("A missing or malformed address can't be judged")
    func requiresASendingDomain() {
        #expect(brand("myGov", nil) == nil)
        #expect(brand("myGov", "") == nil)
    }
}

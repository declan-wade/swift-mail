import Foundation

/// Mail whose display name claims a brand the sending domain doesn't belong to.
///
/// This is deliberately not a classifier and not a score. The one thing it
/// looks at is the mismatch a reader can't reliably see for themselves — the
/// name says `myGov`, the envelope says `prosa.ai` — so what the reader is
/// shown is a fact they can check rather than a hunch they have to trust.
/// That is also why it only ever *suggests*: a table of brands is precise
/// where it fires and silent everywhere else, which is the opposite trade to
/// the one you want backing an automatic move.
///
/// Everything softer than this — mail that is merely junk, or a brand not in
/// the table — is what the Spam button is already for.
nonisolated enum SenderImpersonation {
    struct Brand: Equatable {
        /// What to call the brand in the warning.
        let name: String
        /// Lowercased, letters-and-digits-only forms the display name may use.
        let aliases: [String]
        /// Registrable domains the brand actually sends from. A sending domain
        /// matches one of these exactly or as a subdomain of it, so `gov.au`
        /// covers every `my.gov.au` and `ato.gov.au` without listing them, and
        /// `anz.com.au` covers `e.anz.com.au` but never `anzsecurityemail.com`.
        let domains: [String]

        func sends(from domain: String) -> Bool {
            domains.contains { domain == $0 || domain.hasSuffix(".\($0)") }
        }
    }

    /// Kept short on purpose. Every entry is a brand whose real sending domains
    /// can be stated with confidence; a brand that can't be pinned down that
    /// way would trade a rare catch for routine false alarms, which is how a
    /// warning like this stops being read at all.
    static let brands: [Brand] = [
        Brand(
            name: "myGov",
            aliases: ["mygov", "servicesaustralia", "centrelink", "medicare", "ato", "australiantaxationoffice"],
            // Australian government mail is only ever sent from the one
            // second-level domain, which makes this the cleanest rule here.
            domains: ["gov.au"]
        ),
        Brand(name: "ANZ", aliases: ["anz"], domains: ["anz.com", "anz.com.au"]),
        Brand(
            name: "Commonwealth Bank",
            aliases: ["commbank", "commonwealthbank"],
            domains: ["commbank.com.au", "cba.com.au"]
        ),
        Brand(name: "Westpac", aliases: ["westpac"], domains: ["westpac.com.au"]),
        Brand(name: "NAB", aliases: ["nab"], domains: ["nab.com.au"]),
        Brand(name: "Australia Post", aliases: ["auspost", "australiapost"], domains: ["auspost.com.au"]),
        Brand(name: "Telstra", aliases: ["telstra"], domains: ["telstra.com", "telstra.com.au"]),
        Brand(name: "Optus", aliases: ["optus"], domains: ["optus.com.au"]),
        Brand(name: "PayPal", aliases: ["paypal"], domains: ["paypal.com", "paypal.com.au"]),
        Brand(name: "Apple", aliases: ["apple"], domains: ["apple.com", "icloud.com"]),
        Brand(
            name: "Microsoft",
            aliases: ["microsoft"],
            domains: ["microsoft.com", "microsoftonline.com", "office.com", "live.com"]
        ),
        Brand(
            name: "Amazon",
            aliases: ["amazon"],
            domains: ["amazon.com", "amazon.com.au", "amazonses.com", "amazonaws.com"]
        ),
        Brand(name: "eBay", aliases: ["ebay"], domains: ["ebay.com", "ebay.com.au"]),
        Brand(name: "Netflix", aliases: ["netflix"], domains: ["netflix.com"]),
        Brand(name: "DocuSign", aliases: ["docusign"], domains: ["docusign.com", "docusign.net"]),
        Brand(name: "Xero", aliases: ["xero"], domains: ["xero.com"])
    ]

    /// The brand this message claims to be from while sending from somewhere
    /// else, or nil — which is the answer for the overwhelming majority of
    /// mail, including every sender the table has never heard of.
    static func impersonatedBrand(displayName: String?, address: String?, in brands: [Brand] = brands) -> Brand? {
        guard let domain = SafeSenders.domain(of: address),
              let claimed = claimedBrand(displayName: displayName, in: brands),
              !claimed.sends(from: domain) else {
            return nil
        }

        return claimed
    }

    /// Which brand a display name claims to be.
    ///
    /// A whole word is the primary match, so `ANZ Internet Banking` counts and
    /// `Anzac Day Committee` does not. The run-together form is only accepted
    /// as a *prefix*, and only for aliases long enough to be distinctive: that
    /// is what lets `My Gov` and `MyGov Australia` through while keeping
    /// `Pineapple Express` from reading as Apple.
    static func claimedBrand(displayName: String?, in brands: [Brand] = brands) -> Brand? {
        guard let displayName else {
            return nil
        }

        let words = words(in: displayName)
        guard !words.isEmpty else {
            return nil
        }

        let runTogether = words.joined()

        return brands.first { brand in
            brand.aliases.contains { alias in
                words.contains(alias) || (alias.count >= 5 && runTogether.hasPrefix(alias))
            }
        }
    }

    /// Lowercased letter-and-digit runs: `"my-Gov"` and `"My Gov"` both become
    /// `["my", "gov"]`, so punctuation can't be used to slip past the table.
    static func words(in displayName: String) -> [String] {
        displayName
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

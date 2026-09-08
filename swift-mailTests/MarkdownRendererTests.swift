//
//  MarkdownRendererTests.swift
//  swift-mailTests
//

import Testing
@testable import swift_mail

/// Regression coverage for the defects found in the "Polish, Refinement &
/// QOL" pass. `BlockScanner`/`InlineScanner`/`Heading` etc. are file-private
/// to `MarkdownRenderer.swift`, so these tests exercise the renderer only
/// through its public HTML output — which is also the more honest thing to
/// assert on, since that HTML is what actually ships.
struct MarkdownRendererTests {
    @Test("ATX heading strips a trailing closing sequence, not a leading one")
    func headingTrailingHashes() {
        let html = MarkdownRenderer.bodyHTML(from: "## Heading ##")
        #expect(html.contains(">Heading<"))
        #expect(!html.contains("Heading ##"))
    }

    @Test("A leading hash that isn't a heading marker survives")
    func headingDoesNotEatLeadingContentHash() {
        let html = MarkdownRenderer.bodyHTML(from: "# #tag")
        #expect(html.contains(">#tag<"))
    }

    @Test("A GFM table directly after a paragraph line still parses as a table")
    func tableAfterParagraphIsNotSwallowed() {
        let markdown = """
        Some intro text
        | A | B |
        |---|---|
        | 1 | 2 |
        """

        let html = MarkdownRenderer.bodyHTML(from: markdown)
        #expect(html.contains("<table"))
        #expect(html.contains("<th"))
    }

    @Test("A run of three delimiters is bold-and-italic, with no stray marker")
    func tripleDelimiterIsBoldItalic() {
        let html = MarkdownRenderer.bodyHTML(from: "***bold italic***")
        #expect(html.contains("<strong><em>bold italic</em></strong>"))
        #expect(!html.contains("*"))
    }

    @Test("A short bare www URL still linkifies")
    func shortBareURLLinkifies() {
        let html = MarkdownRenderer.bodyHTML(from: "www.a.co")
        #expect(html.contains("<a href=\"https://www.a.co\""))
    }

    @Test("Bare URL detection is case-insensitive")
    func bareURLIsCaseInsensitive() {
        let httpsHTML = MarkdownRenderer.bodyHTML(from: "HTTPS://EXAMPLE.COM")
        #expect(httpsHTML.contains("<a href="))

        let wwwHTML = MarkdownRenderer.bodyHTML(from: "WWW.EXAMPLE.COM")
        #expect(wwwHTML.contains("<a href="))
    }

    @Test("A bare scheme with nothing after it is not linkified")
    func bareSchemeAloneIsNotLinkified() {
        let html = MarkdownRenderer.bodyHTML(from: "check out http:// sometime")
        #expect(!html.contains("<a href"))
    }

    @Test("A disallowed URL scheme never reaches an href attribute")
    func disallowedSchemeIsDropped() {
        let html = MarkdownRenderer.bodyHTML(from: "[click me](javascript:alert(1))")
        // The link syntax fails to resolve to a safe destination and falls
        // back to literal text — inert, but the raw scheme string may still
        // appear on the page. What must never happen is `javascript:` landing
        // inside an `href="..."`, where a mail client would treat it as live.
        #expect(!html.contains("href=\"javascript:"))
    }

    @Test("The wire palette emits explicit hex, matching the outgoing message")
    func wirePaletteIsExplicitHex() {
        let html = MarkdownRenderer.htmlDocument(from: "hello", palette: .wire)
        #expect(html.contains("#1d1d1f"))
    }

    @Test("The preview palette emits semantic AppKit colors instead")
    func previewPaletteIsSemantic() {
        let html = MarkdownRenderer.htmlDocument(from: "hello", palette: .preview)
        #expect(html.contains("-apple-system-label"))
        #expect(!html.contains("#1d1d1f"))
    }

    @Test("Raw HTML in the source is escaped, never passed through")
    func rawHTMLIsEscaped() {
        let html = MarkdownRenderer.bodyHTML(from: "<script>alert(1)</script>")
        #expect(!html.contains("<script>"))
    }
}

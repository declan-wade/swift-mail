//
//  MarkdownDocumentTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// `MarkdownDocument` rebuilds block nesting from each run's flattened,
/// innermost-first `PresentationIntent.components` — these tests pin down
/// that reconstruction for the constructs `MarkdownPreview` draws.
struct MarkdownDocumentTests {
    @Test("Empty input parses to no blocks")
    func emptyInput() {
        #expect(MarkdownDocument.parse("").isEmpty)
        #expect(MarkdownDocument.parse("   \n\n").isEmpty)
    }

    @Test("A heading parses with its level")
    func heading() {
        let blocks = MarkdownDocument.parse("## Section")
        #expect(blocks.count == 1)

        guard case .heading(let text, let level, _) = blocks.first else {
            Issue.record("Expected a heading block")
            return
        }

        #expect(level == 2)
        #expect(String(text.characters) == "Section")
    }

    @Test("An unordered list groups each item's content under it")
    func unorderedList() {
        let blocks = MarkdownDocument.parse("- one\n- two\n")
        #expect(blocks.count == 1)

        guard case .list(let items, let isOrdered, _, _) = blocks.first else {
            Issue.record("Expected a list block")
            return
        }

        #expect(!isOrdered)
        #expect(items.count == 2)

        guard case .paragraph(let first, _) = items[0].first else {
            Issue.record("Expected the first item's content to be a paragraph")
            return
        }
        #expect(String(first.characters) == "one")
    }

    @Test("An ordered list preserves its starting number")
    func orderedListStart() {
        let blocks = MarkdownDocument.parse("3. three\n4. four\n")

        guard case .list(_, let isOrdered, let start, _) = blocks.first else {
            Issue.record("Expected a list block")
            return
        }

        #expect(isOrdered)
        #expect(start == 3)
    }

    @Test("A block quote nests its paragraph")
    func blockQuote() {
        let blocks = MarkdownDocument.parse("> quoted text")

        guard case .blockQuote(let children, _) = blocks.first else {
            Issue.record("Expected a block quote")
            return
        }

        #expect(children.count == 1)
    }

    @Test("A fenced code block keeps its language hint and literal text")
    func codeBlock() {
        let blocks = MarkdownDocument.parse("```swift\nlet x = 1\n```")

        guard case .codeBlock(let text, let language, _) = blocks.first else {
            Issue.record("Expected a code block")
            return
        }

        #expect(language == "swift")
        #expect(text.contains("let x = 1"))
    }

    @Test("A GFM table reports its column count, headers, and rows")
    func table() {
        let blocks = MarkdownDocument.parse("| A | B |\n|---|---|\n| 1 | 2 |\n")

        guard case .table(let columnCount, let headers, let rows, _) = blocks.first else {
            Issue.record("Expected a table")
            return
        }

        #expect(columnCount == 2)
        #expect(headers.map { String($0.characters) } == ["A", "B"])
        #expect(rows.count == 1)
        #expect(rows[0].map { String($0.characters) } == ["1", "2"])
    }

    @Test("A javascript: link is stripped so the native preview can't run it either")
    func disallowedLinkSchemeIsStripped() {
        let blocks = MarkdownDocument.parse("[click me](javascript:alert(1))")

        guard case .paragraph(let text, _) = blocks.first else {
            Issue.record("Expected a paragraph")
            return
        }

        for run in text.runs {
            #expect(run.link == nil)
        }
    }

    @Test("An https link survives sanitization")
    func allowedLinkSchemeSurvives() {
        let blocks = MarkdownDocument.parse("[click me](https://example.com)")

        guard case .paragraph(let text, _) = blocks.first else {
            Issue.record("Expected a paragraph")
            return
        }

        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }
}

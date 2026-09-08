import Foundation
import Testing
@testable import swift_mail

struct MarkdownBlockPrefixTests {
    private func toggle(_ kind: MarkdownBlockPrefix.Kind, _ line: String, ordinal: Int = 1) -> String {
        MarkdownBlockPrefix.toggling(kind, in: line, ordinal: ordinal)
    }

    @Test("A prefix is applied to a plain line and removed on a second press")
    func applyAndRemove() {
        #expect(toggle(.heading(level: 1), "Title") == "# Title")
        #expect(toggle(.heading(level: 1), "# Title") == "Title")
        #expect(toggle(.bullet, "Item") == "- Item")
        #expect(toggle(.bullet, "- Item") == "Item")
        #expect(toggle(.quote, "Said") == "> Said")
        #expect(toggle(.quote, "> Said") == "Said")
    }

    /// The point of parsing before applying: prefixes replace, never stack.
    @Test("A different prefix replaces the existing one instead of stacking")
    func prefixesReplaceRatherThanStack() {
        #expect(toggle(.heading(level: 1), "## Subtitle") == "# Subtitle")
        #expect(toggle(.heading(level: 2), "# Title") == "## Title")
        #expect(toggle(.bullet, "1. Item") == "- Item")
        #expect(toggle(.numbered, "- Item") == "1. Item")
        #expect(toggle(.quote, "### Heading") == "> Heading")
    }

    @Test("Bullets and ordinals are matched by kind, not by exact marker")
    func markersMatchByKind() {
        // `*` and `+` are bullets too, so the shortcut clears them.
        #expect(toggle(.bullet, "* Item") == "Item")
        #expect(toggle(.bullet, "+ Item") == "Item")
        // Any ordinal is a numbered item, not just 1.
        #expect(toggle(.numbered, "7. Item") == "Item")
        #expect(toggle(.numbered, "3) Item") == "Item")
    }

    @Test("Indentation is preserved so nested items stay nested")
    func indentationSurvives() {
        #expect(toggle(.bullet, "    Nested") == "    - Nested")
        #expect(toggle(.heading(level: 2), "\tTabbed") == "\t## Tabbed")
        #expect(toggle(.bullet, "  - Nested") == "  Nested")
    }

    @Test("Ordinals number a multi-line selection in sequence")
    func ordinalsIncrement() {
        let numbered = ["First", "Second", "Third"]
            .enumerated()
            .map { toggle(.numbered, $1, ordinal: $0 + 1) }

        #expect(numbered == ["1. First", "2. Second", "3. Third"])
    }

    @Test("Things that only look like prefixes are left alone")
    func nearMissesAreNotPrefixes() {
        // No space after the marker, so these are ordinary text.
        #expect(toggle(.bullet, "#Hashtag") == "- #Hashtag")
        #expect(toggle(.bullet, "-dash") == "- -dash")
        #expect(toggle(.bullet, "2024 was a year") == "- 2024 was a year")
        // Seven hashes is past the heading limit.
        #expect(toggle(.bullet, "####### Deep") == "- ####### Deep")
    }

    @Test("An empty line still takes a prefix, so a list can be started")
    func emptyLineTakesPrefix() {
        #expect(toggle(.bullet, "") == "- ")
        #expect(toggle(.heading(level: 1), "") == "# ")
    }
}

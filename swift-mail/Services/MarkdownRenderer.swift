import Foundation

/// Converts a Markdown draft into the HTML that ships in the outgoing message.
///
/// swift-mail composes Markdown first: the raw Markdown is sent verbatim as the
/// `text/plain` alternative and this renderer produces the `text/html` one. The
/// supported subset is hand rolled rather than delegating to
/// `AttributedString(markdown:)` because mail needs the block-level constructs
/// (lists, quotes, fenced code, tables) that it does not model, and because every
/// element has to carry inline styles — mail clients routinely strip `<style>`
/// blocks, so nothing here may rely on a stylesheet to stay readable.
///
/// Raw HTML in the source is escaped rather than passed through. A Markdown-first
/// composer has no reason to emit tags the user did not ask for, and escaping
/// keeps a pasted snippet from rewriting the message around it.
nonisolated enum MarkdownRenderer {
    /// An HTML fragment, suitable for embedding in a message body.
    static func bodyHTML(from markdown: String) -> String {
        var scanner = BlockScanner(markdown: markdown)
        return scanner.render()
    }

    /// A full document, used for the compose preview and as the `text/html` part.
    static func htmlDocument(from markdown: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
        </head>
        <body style="\(Style.body)">
        \(bodyHTML(from: markdown))
        </body>
        </html>
        """
    }

    /// The `text/plain` alternative. Markdown *is* the plain text representation,
    /// which is the whole point of composing this way.
    static func plainText(from markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

// MARK: - Styling

extension MarkdownRenderer {
    nonisolated enum Style {
        static let body = "margin:0;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;color:#1d1d1f;"
        static let paragraph = "margin:0 0 12px 0;"
        static let list = "margin:0 0 12px 0;padding-left:24px;"
        static let listItem = "margin:0 0 4px 0;"
        static let blockquote = "margin:0 0 12px 0;padding:2px 0 2px 12px;border-left:3px solid #d2d2d7;color:#515154;"
        static let codeBlock = "margin:0 0 12px 0;padding:10px 12px;background:#f5f5f7;border-radius:6px;white-space:pre-wrap;"
        static let code = "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;"
        static let codeSpan = "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;background:#f5f5f7;border-radius:4px;padding:1px 4px;"
        static let rule = "border:0;border-top:1px solid #d2d2d7;margin:20px 0;"
        static let link = "color:#0066cc;"
        static let image = "max-width:100%;height:auto;"
        static let table = "border-collapse:collapse;margin:0 0 12px 0;"
        static let tableHeaderCell = "border:1px solid #d2d2d7;padding:6px 10px;background:#f5f5f7;font-weight:600;"
        static let tableCell = "border:1px solid #d2d2d7;padding:6px 10px;"

        static func heading(level: Int) -> String {
            let size: String
            switch level {
            case 1: size = "22px"
            case 2: size = "19px"
            case 3: size = "17px"
            case 4: size = "15px"
            default: size = "14px"
            }

            return "margin:20px 0 8px 0;line-height:1.25;font-weight:600;font-size:\(size);"
        }
    }
}

// MARK: - Block parsing

nonisolated private struct BlockScanner {
    private let lines: [String]
    private var index = 0

    init(markdown: String) {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")

        self.init(lines: normalized.components(separatedBy: "\n"))
    }

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func render() -> String {
        var blocks: [String] = []

        while let line = peek() {
            if line.isBlankLine {
                index += 1
                continue
            }

            if let fence = CodeFence(line: line) {
                blocks.append(renderCodeBlock(opening: fence))
            } else if line.isThematicBreak {
                index += 1
                blocks.append("<hr style=\"\(MarkdownRenderer.Style.rule)\">")
            } else if let heading = Heading(line: line) {
                index += 1
                blocks.append(heading.html)
            } else if line.isBlockquote {
                blocks.append(renderBlockquote())
            } else if let table = renderTable() {
                blocks.append(table)
            } else if ListMarker(line: line) != nil {
                blocks.append(renderList())
            } else {
                blocks.append(renderParagraph())
            }
        }

        return blocks.joined(separator: "\n")
    }

    private func peek() -> String? {
        index < lines.count ? lines[index] : nil
    }

    /// True when the line would begin a block other than the paragraph currently
    /// being gathered, which is what terminates lazy continuation.
    private func startsNewBlock(_ line: String) -> Bool {
        line.isBlankLine
            || line.isThematicBreak
            || line.isBlockquote
            || CodeFence(line: line) != nil
            || Heading(line: line) != nil
            || ListMarker(line: line) != nil
    }

    private mutating func renderCodeBlock(opening: CodeFence) -> String {
        index += 1

        var content: [String] = []
        while let line = peek() {
            if let fence = CodeFence(line: line), fence.closes(opening) {
                index += 1
                break
            }

            content.append(line)
            index += 1
        }

        let code = content.joined(separator: "\n").htmlEscaped()
        let language = opening.language.map { " data-language=\"\($0.htmlEscaped())\"" } ?? ""

        return "<pre style=\"\(MarkdownRenderer.Style.codeBlock)\"\(language)><code style=\"\(MarkdownRenderer.Style.code)\">\(code)</code></pre>"
    }

    private mutating func renderBlockquote() -> String {
        var quoted: [String] = []

        while let line = peek() {
            if line.isBlockquote {
                quoted.append(line.strippingBlockquoteMarker())
                index += 1
                continue
            }

            // Lazy continuation: an unmarked line still belongs to the quote.
            if !startsNewBlock(line), !quoted.isEmpty {
                quoted.append(line)
                index += 1
                continue
            }

            break
        }

        var scanner = BlockScanner(lines: quoted)
        return "<blockquote style=\"\(MarkdownRenderer.Style.blockquote)\">\(scanner.render())</blockquote>"
    }

    private mutating func renderList() -> String {
        guard let first = ListMarker(line: lines[index]) else {
            return ""
        }

        let isOrdered = first.isOrdered
        var items: [String] = []

        while let line = peek(), let marker = ListMarker(line: line), marker.isOrdered == isOrdered {
            index += 1
            items.append(renderListItem(marker: marker))
        }

        let tag = isOrdered ? "ol" : "ul"
        let start = isOrdered && first.number != 1 ? " start=\"\(first.number)\"" : ""
        let body = items
            .map { "<li style=\"\(MarkdownRenderer.Style.listItem)\">\($0)</li>" }
            .joined(separator: "\n")

        return "<\(tag) style=\"\(MarkdownRenderer.Style.list)\"\(start)>\n\(body)\n</\(tag)>"
    }

    /// Gathers everything indented under a list marker and renders it recursively,
    /// which is what gives nested lists, indented code, and multi-paragraph items.
    private mutating func renderListItem(marker: ListMarker) -> String {
        var itemLines = [marker.content]
        var isLoose = false

        while let line = peek() {
            if line.isBlankLine {
                // A blank line only stays in the item if indented content follows it.
                let next = index + 1 < lines.count ? lines[index + 1] : nil
                guard let next, !next.isBlankLine, next.leadingSpaceCount >= marker.contentIndent else {
                    break
                }

                itemLines.append("")
                isLoose = true
                index += 1
                continue
            }

            guard line.leadingSpaceCount >= marker.contentIndent else {
                break
            }

            itemLines.append(String(line.dropFirst(marker.contentIndent)))
            index += 1
        }

        var scanner = BlockScanner(lines: itemLines)
        let rendered = scanner.render()

        return isLoose ? rendered : unwrappingLeadingParagraph(rendered)
    }

    /// A tight item's own text is not a paragraph — dropping the wrapper is what
    /// keeps `- a` and an item that also carries a nested list spaced alike.
    private func unwrappingLeadingParagraph(_ html: String) -> String {
        let prefix = "<p style=\"\(MarkdownRenderer.Style.paragraph)\">"

        guard html.hasPrefix(prefix), let close = html.range(of: "</p>") else {
            return html
        }

        let inner = html[html.index(html.startIndex, offsetBy: prefix.count)..<close.lowerBound]
        guard !inner.contains("<p style=") else {
            return html
        }

        return String(inner) + String(html[close.upperBound...])
    }

    private mutating func renderTable() -> String? {
        guard index + 1 < lines.count else {
            return nil
        }

        let headerLine = lines[index]
        guard headerLine.contains("|"),
              let alignments = TableAlignment.parseDelimiterRow(lines[index + 1]) else {
            return nil
        }

        let headers = headerLine.tableCells()
        guard headers.count == alignments.count else {
            return nil
        }

        index += 2

        var rows: [[String]] = []
        while let line = peek(), !line.isBlankLine, line.contains("|") {
            rows.append(line.tableCells())
            index += 1
        }

        func cell(_ text: String, at column: Int, isHeader: Bool) -> String {
            let tag = isHeader ? "th" : "td"
            let base = isHeader ? MarkdownRenderer.Style.tableHeaderCell : MarkdownRenderer.Style.tableCell
            let alignment = alignments.indices.contains(column) ? alignments[column].css : ""

            return "<\(tag) style=\"\(base)\(alignment)\">\(InlineScanner.render(text))</\(tag)>"
        }

        let head = headers.enumerated()
            .map { cell($0.element, at: $0.offset, isHeader: true) }
            .joined()

        let body = rows.map { row in
            let cells = (0..<alignments.count)
                .map { cell($0 < row.count ? row[$0] : "", at: $0, isHeader: false) }
                .joined()

            return "<tr>\(cells)</tr>"
        }.joined(separator: "\n")

        return """
        <table style="\(MarkdownRenderer.Style.table)">
        <thead><tr>\(head)</tr></thead>
        <tbody>
        \(body)
        </tbody>
        </table>
        """
    }

    private mutating func renderParagraph() -> String {
        var rendered: [String] = []

        while let line = peek() {
            if !rendered.isEmpty, startsNewBlock(line) {
                break
            }

            if line.isBlankLine {
                break
            }

            // Two trailing spaces, or a trailing backslash, force a hard break.
            let hasHardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            let text = line.hasSuffix("\\") ? String(line.dropLast()) : line

            rendered.append(InlineScanner.render(text) + (hasHardBreak ? "<br>" : ""))
            index += 1
        }

        return "<p style=\"\(MarkdownRenderer.Style.paragraph)\">\(rendered.joined(separator: "\n"))</p>"
    }
}

// MARK: - Block descriptors

nonisolated private struct CodeFence {
    let character: Character
    let length: Int
    let language: String?

    init?(line: String) {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }

        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else {
            return nil
        }

        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)

        // An info string may not contain a backtick when the fence is backticks.
        if first == "`", info.contains("`") {
            return nil
        }

        character = first
        length = run.count
        language = info.isEmpty ? nil : info
    }

    func closes(_ opening: CodeFence) -> Bool {
        character == opening.character && length >= opening.length && language == nil
    }
}

nonisolated private struct Heading {
    let level: Int
    let text: String

    init?(line: String) {
        let trimmed = line.drop { $0 == " " }
        let hashes = trimmed.prefix { $0 == "#" }

        guard (1...6).contains(hashes.count) else {
            return nil
        }

        let remainder = trimmed.dropFirst(hashes.count)
        guard remainder.isEmpty || remainder.first == " " else {
            return nil
        }

        level = hashes.count
        text = remainder
            .trimmingCharacters(in: .whitespaces)
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
    }

    var html: String {
        "<h\(level) style=\"\(MarkdownRenderer.Style.heading(level: level))\">\(InlineScanner.render(text))</h\(level)>"
    }
}

nonisolated private struct ListMarker {
    let isOrdered: Bool
    let number: Int
    let content: String
    /// Column at which the item's own content begins, used to capture nested blocks.
    let contentIndent: Int

    init?(line: String) {
        let indent = line.leadingSpaceCount
        guard indent < 4 else {
            return nil
        }

        var rest = Substring(line).dropFirst(indent)
        var markerLength = 0
        var isOrdered = false
        var number = 1

        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            markerLength = 1
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else {
                return nil
            }

            let afterDigits = rest.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
                return nil
            }

            isOrdered = true
            number = Int(digits) ?? 1
            markerLength = digits.count + 1
            rest = afterDigits.dropFirst()
        }

        // A marker needs whitespace after it, otherwise `-3 degrees` becomes a list.
        guard let separator = rest.first, separator == " " else {
            return nil
        }

        let spaces = rest.prefix { $0 == " " }.count

        self.isOrdered = isOrdered
        self.number = number
        self.content = String(rest.dropFirst(spaces))
        self.contentIndent = indent + markerLength + spaces
    }
}

nonisolated private enum TableAlignment {
    case none
    case leading
    case center
    case trailing

    var css: String {
        switch self {
        case .none: return ""
        case .leading: return "text-align:left;"
        case .center: return "text-align:center;"
        case .trailing: return "text-align:right;"
        }
    }

    static func parseDelimiterRow(_ line: String) -> [TableAlignment]? {
        let cells = line.tableCells()
        guard !cells.isEmpty else {
            return nil
        }

        var alignments: [TableAlignment] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let dashes = trimmed.drop { $0 == ":" }.prefix { $0 == "-" }

            guard !dashes.isEmpty,
                  trimmed.allSatisfy({ $0 == "-" || $0 == ":" }) else {
                return nil
            }

            switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.leading)
            case (false, true): alignments.append(.trailing)
            case (false, false): alignments.append(.none)
            }
        }

        return alignments
    }
}

// MARK: - Inline parsing

nonisolated private enum InlineScanner {
    static func render(_ text: String) -> String {
        var output = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            switch character {
            case "\\" where index + 1 < characters.count && characters[index + 1].isMarkdownPunctuation:
                output += String(characters[index + 1]).htmlEscaped()
                index += 2

            case "`":
                if let span = codeSpan(characters, from: index) {
                    output += span.html
                    index = span.next
                } else {
                    output += "`"
                    index += 1
                }

            case "*", "_", "~":
                if let emphasis = emphasis(characters, from: index) {
                    output += emphasis.html
                    index = emphasis.next
                } else {
                    output += String(character)
                    index += 1
                }

            case "!" where index + 1 < characters.count && characters[index + 1] == "[":
                if let image = link(characters, from: index + 1, isImage: true) {
                    output += image.html
                    index = image.next
                } else {
                    output += "!"
                    index += 1
                }

            case "[":
                if let anchor = link(characters, from: index, isImage: false) {
                    output += anchor.html
                    index = anchor.next
                } else {
                    output += "["
                    index += 1
                }

            case "<":
                if let autolink = autolink(characters, from: index) {
                    output += autolink.html
                    index = autolink.next
                } else {
                    output += "&lt;"
                    index += 1
                }

            case "h", "w":
                if let bare = bareURL(characters, from: index) {
                    output += bare.html
                    index = bare.next
                } else {
                    output += String(character)
                    index += 1
                }

            case "&":
                output += "&amp;"
                index += 1

            case ">":
                output += "&gt;"
                index += 1

            default:
                output += String(character)
                index += 1
            }
        }

        return output
    }

    private static func codeSpan(_ characters: [Character], from start: Int) -> (html: String, next: Int)? {
        let fence = characters[start...].prefix { $0 == "`" }.count
        var index = start + fence

        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }

            let run = characters[index...].prefix { $0 == "`" }.count
            guard run == fence else {
                index += run
                continue
            }

            let code = String(characters[(start + fence)..<index])
            guard !code.isEmpty else {
                return nil
            }

            let html = "<code style=\"\(MarkdownRenderer.Style.codeSpan)\">\(code.htmlEscaped())</code>"
            return (html, index + fence)
        }

        return nil
    }

    private static func emphasis(_ characters: [Character], from start: Int) -> (html: String, next: Int)? {
        let marker = characters[start]
        let run = characters[start...].prefix { $0 == marker }.count

        let delimiterLength: Int
        let tag: String

        switch (marker, run) {
        case ("~", 2...):
            delimiterLength = 2
            tag = "del"
        case ("~", _):
            return nil
        case (_, 2...):
            delimiterLength = 2
            tag = "strong"
        default:
            delimiterLength = 1
            tag = "em"
        }

        // Intraword underscores are far more often snake_case than emphasis.
        if marker == "_" {
            let before = start > 0 ? characters[start - 1] : " "
            if before.isLetter || before.isNumber {
                return nil
            }
        }

        let contentStart = start + delimiterLength
        guard contentStart < characters.count, characters[contentStart] != " " else {
            return nil
        }

        var index = contentStart
        while index < characters.count {
            guard characters[index] == marker else {
                index += 1
                continue
            }

            let closing = characters[index...].prefix { $0 == marker }.count
            guard closing >= delimiterLength, characters[index - 1] != " " else {
                index += closing
                continue
            }

            if marker == "_" {
                let after = index + delimiterLength < characters.count ? characters[index + delimiterLength] : " "
                if after.isLetter || after.isNumber {
                    index += closing
                    continue
                }
            }

            let content = String(characters[contentStart..<index])
            return ("<\(tag)>\(render(content))</\(tag)>", index + delimiterLength)
        }

        return nil
    }

    private static func link(_ characters: [Character], from start: Int, isImage: Bool) -> (html: String, next: Int)? {
        guard let labelEnd = characters.firstIndex(of: "]", from: start + 1),
              labelEnd + 1 < characters.count,
              characters[labelEnd + 1] == "(",
              let destinationEnd = characters.firstIndex(of: ")", from: labelEnd + 2) else {
            return nil
        }

        let label = String(characters[(start + 1)..<labelEnd])
        let destination = String(characters[(labelEnd + 2)..<destinationEnd])
            .trimmingCharacters(in: .whitespaces)

        guard let url = SafeURL(destination) else {
            return nil
        }

        let next = destinationEnd + 1
        if isImage {
            let html = "<img src=\"\(url.attributeValue)\" alt=\"\(label.htmlEscaped())\" style=\"\(MarkdownRenderer.Style.image)\">"
            return (html, next)
        }

        let html = "<a href=\"\(url.attributeValue)\" style=\"\(MarkdownRenderer.Style.link)\">\(render(label))</a>"
        return (html, next)
    }

    private static func autolink(_ characters: [Character], from start: Int) -> (html: String, next: Int)? {
        guard let end = characters.firstIndex(of: ">", from: start + 1) else {
            return nil
        }

        let candidate = String(characters[(start + 1)..<end])
        guard !candidate.contains(" "), let url = SafeURL(candidate) else {
            return nil
        }

        let html = "<a href=\"\(url.attributeValue)\" style=\"\(MarkdownRenderer.Style.link)\">\(candidate.htmlEscaped())</a>"
        return (html, end + 1)
    }

    private static func bareURL(_ characters: [Character], from start: Int) -> (html: String, next: Int)? {
        let remainder = String(characters[start...])
        let scheme = ["https://", "http://", "www."].first { remainder.hasPrefix($0) }
        guard scheme != nil else {
            return nil
        }

        var end = start
        while end < characters.count, !characters[end].isWhitespace, characters[end] != "<", characters[end] != ")" {
            end += 1
        }

        // Sentence punctuation trailing a URL belongs to the sentence, not the link.
        while end > start, characters[end - 1].isTrailingPunctuation {
            end -= 1
        }

        let text = String(characters[start..<end])
        guard text.count > 8, let url = SafeURL(text.hasPrefix("www.") ? "https://\(text)" : text) else {
            return nil
        }

        let html = "<a href=\"\(url.attributeValue)\" style=\"\(MarkdownRenderer.Style.link)\">\(text.htmlEscaped())</a>"
        return (html, end)
    }
}

/// A destination that is safe to drop into an `href`/`src`.
///
/// An explicit, allow-listed scheme is required. That keeps `javascript:` and
/// friends away from the recipient, and it also means a fragment such as `<b>`
/// is never mistaken for an autolink — relative destinations have no meaning in
/// a mail message anyway.
nonisolated private struct SafeURL {
    static let allowedSchemes = ["http://", "https://", "mailto:", "tel:"]

    let attributeValue: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        guard Self.allowedSchemes.contains(where: { lowercased.hasPrefix($0) }) else {
            return nil
        }

        attributeValue = trimmed.htmlEscaped()
    }
}

// MARK: - Line helpers

nonisolated private extension String {
    var isBlankLine: Bool {
        allSatisfy(\.isWhitespace)
    }

    var leadingSpaceCount: Int {
        prefix { $0 == " " }.count
    }

    var isThematicBreak: Bool {
        let condensed = filter { $0 != " " }
        guard condensed.count >= 3, let first = condensed.first else {
            return false
        }

        return (first == "-" || first == "*" || first == "_") && condensed.allSatisfy { $0 == first }
    }

    var isBlockquote: Bool {
        leadingSpaceCount < 4 && dropFirst(leadingSpaceCount).first == ">"
    }

    func strippingBlockquoteMarker() -> String {
        var rest = dropFirst(leadingSpaceCount)
        guard rest.first == ">" else {
            return self
        }

        rest = rest.dropFirst()
        if rest.first == " " {
            rest = rest.dropFirst()
        }

        return String(rest)
    }

    /// Splits a GFM table row, discarding the optional leading and trailing pipes.
    func tableCells() -> [String] {
        var row = trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") {
            row = String(row.dropFirst())
        }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") {
            row = String(row.dropLast())
        }

        return row
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

nonisolated private extension Character {
    var isMarkdownPunctuation: Bool {
        "\\`*_{}[]()#+-.!|~>&\"'".contains(self)
    }

    var isTrailingPunctuation: Bool {
        ".,;:!?".contains(self)
    }
}

nonisolated private extension Array where Element == Character {
    func firstIndex(of character: Character, from start: Int) -> Int? {
        var index = start
        while index < count {
            if self[index] == "\\" {
                index += 2
                continue
            }

            if self[index] == character {
                return index
            }

            index += 1
        }

        return nil
    }
}

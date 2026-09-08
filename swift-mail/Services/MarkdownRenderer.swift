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
    /// The color palette in effect for the render currently on the stack.
    ///
    /// Threading a parameter through `BlockScanner`/`InlineScanner` for a value
    /// that never changes mid-render would mean touching every recursive call
    /// site; a task-local reads cleanly from `Style` instead while staying just
    /// as concurrency-safe, since `Palette` is an immutable `Sendable` value.
    @TaskLocal fileprivate static var palette: Palette = .wire

    /// An HTML fragment, suitable for embedding in a message body.
    static func bodyHTML(from markdown: String, palette: Palette = .wire) -> String {
        Self.$palette.withValue(palette) {
            var scanner = BlockScanner(markdown: markdown)
            return scanner.render()
        }
    }

    /// A full document. `palette` defaults to `.wire`, the colors that actually
    /// ship in the `text/html` part; the compose preview passes `.preview` so it
    /// reads correctly in both appearances instead of showing the wire colors
    /// against the window's own background.
    static func htmlDocument(from markdown: String, palette: Palette = .wire) -> String {
        Self.$palette.withValue(palette) {
            """
            <!doctype html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="color-scheme" content="light dark">
                <style>
                    :root { color-scheme: light dark; }
                    @media (prefers-color-scheme: dark) {
                        body { color: \(Palette.wireDark.text) !important; }
                        blockquote { color: \(Palette.wireDark.secondaryText) !important; border-left-color: \(Palette.wireDark.rule) !important; }
                        hr { border-top-color: \(Palette.wireDark.rule) !important; }
                        pre, code { background: \(Palette.wireDark.surface) !important; }
                        a { color: \(Palette.wireDark.link) !important; }
                        th, td { border-color: \(Palette.wireDark.rule) !important; }
                        th { background: \(Palette.wireDark.surface) !important; }
                    }
                </style>
            </head>
            <body style="\(Style.body)">
            \(bodyHTML(from: markdown, palette: palette))
            </body>
            </html>
            """
        }
    }

    /// The `text/plain` alternative. Markdown *is* the plain text representation,
    /// which is the whole point of composing this way.
    static func plainText(from markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

// MARK: - Palette

extension MarkdownRenderer {
    /// The colors an emitted document's inline styles carry.
    ///
    /// `.wire` is explicit hex because mail clients routinely strip `<style>`
    /// blocks — see the file-level note above — so the inline styles need to
    /// stand alone. `.preview` uses AppKit's semantic system colors, valid only
    /// because the preview always renders inside our own `WKWebView`, never in
    /// a recipient's mail client.
    nonisolated struct Palette: Sendable {
        let text: String
        let secondaryText: String
        let rule: String
        let surface: String
        let link: String

        static let wire = Palette(
            text: "#1d1d1f",
            secondaryText: "#515154",
            rule: "#d2d2d7",
            surface: "#f5f5f7",
            link: "#0066cc"
        )

        /// The dark-mode variant of `.wire`, used only inside the `<style>`
        /// override on the outgoing document — inline styles stay `.wire`
        /// verbatim as the no-CSS fallback.
        fileprivate static let wireDark = Palette(
            text: "#f5f5f7",
            secondaryText: "#a1a1a6",
            rule: "#48484a",
            surface: "#2c2c2e",
            link: "#409cff"
        )

        static let preview = Palette(
            text: "-apple-system-label",
            secondaryText: "-apple-system-secondary-label",
            rule: "-apple-system-separator",
            surface: "color-mix(in srgb, currentColor 8%, transparent)",
            link: "-apple-system-blue"
        )
    }
}

// MARK: - Styling

extension MarkdownRenderer {
    nonisolated enum Style {
        private static var palette: Palette { MarkdownRenderer.palette }

        static var body: String { "margin:0;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;color:\(palette.text);" }
        static let paragraph = "margin:0 0 12px 0;"
        static let list = "margin:0 0 12px 0;padding-left:24px;"
        static let listItem = "margin:0 0 4px 0;"
        static var blockquote: String { "margin:0 0 12px 0;padding:2px 0 2px 12px;border-left:3px solid \(palette.rule);color:\(palette.secondaryText);" }
        static var codeBlock: String { "margin:0 0 12px 0;padding:10px 12px;background:\(palette.surface);border-radius:6px;white-space:pre-wrap;" }
        static let code = "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;"
        static var codeSpan: String { "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;background:\(palette.surface);border-radius:4px;padding:1px 4px;" }
        static var rule: String { "border:0;border-top:1px solid \(palette.rule);margin:20px 0;" }
        static var link: String { "color:\(palette.link);" }
        static let image = "max-width:100%;height:auto;"
        static let table = "border-collapse:collapse;margin:0 0 12px 0;"
        static var tableHeaderCell: String { "border:1px solid \(palette.rule);padding:6px 10px;background:\(palette.surface);font-weight:600;" }
        static var tableCell: String { "border:1px solid \(palette.rule);padding:6px 10px;" }

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

    /// True when the line at `index` would begin a block other than the
    /// paragraph currently being gathered, which is what terminates lazy
    /// continuation.
    private func startsNewBlock(at index: Int) -> Bool {
        guard index < lines.count else {
            return false
        }

        let line = lines[index]

        if line.isBlankLine
            || line.isThematicBreak
            || line.isBlockquote
            || CodeFence(line: line) != nil
            || Heading(line: line) != nil
            || ListMarker(line: line) != nil {
            return true
        }

        // A GFM table's header row is otherwise indistinguishable from a plain
        // paragraph line, so a table written directly after a paragraph (no
        // blank line between) would silently be swallowed into it. Only the
        // delimiter row on the *next* line proves this one starts a table.
        if line.contains("|"), index + 1 < lines.count,
           let alignments = TableAlignment.parseDelimiterRow(lines[index + 1]),
           line.tableCells().count == alignments.count {
            return true
        }

        return false
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
            if !startsNewBlock(at: index), !quoted.isEmpty {
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
            if !rendered.isEmpty, startsNewBlock(at: index) {
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

        // An ATX heading may carry an optional closing sequence of hashes
        // (`## Heading ##`) — trailing, not leading, so a leading `#` such as
        // in `# #tag` is content and must survive.
        let trimmedRemainder = remainder.trimmingCharacters(in: .whitespaces)
        text = String(trimmedRemainder.reversed().drop { $0 == "#" }.reversed())
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

            case "h", "w", "H", "W":
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
        case (_, 3):
            // A run of exactly three is bold-and-italic together
            // (`***text***`), not `strong` with a stray leftover marker.
            delimiterLength = 3
            tag = "strong+em"
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
            let html = tag == "strong+em"
                ? "<strong><em>\(render(content))</em></strong>"
                : "<\(tag)>\(render(content))</\(tag)>"
            return (html, index + delimiterLength)
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

    private static let bareURLSchemes = ["https://", "http://", "www."]

    /// Case-insensitive prefix check against `bareURLSchemes` that only ever
    /// compares a handful of characters, unlike materializing
    /// `String(characters[start...])` on every `h`/`w` character in the
    /// document, which made linkifying long bodies quadratic.
    private static func matchingScheme(_ characters: [Character], at start: Int) -> String? {
        bareURLSchemes.first { scheme in
            let schemeChars = Array(scheme)
            guard start + schemeChars.count <= characters.count else {
                return false
            }

            for offset in 0..<schemeChars.count where characters[start + offset].lowercased() != schemeChars[offset].lowercased() {
                return false
            }

            return true
        }
    }

    private static func bareURL(_ characters: [Character], from start: Int) -> (html: String, next: Int)? {
        guard let scheme = matchingScheme(characters, at: start) else {
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

        // Require something beyond the bare scheme itself, so `http://` or
        // `www.` alone isn't linkified — but a short real host like `www.a.co`
        // still qualifies, unlike the old flat "more than 8 characters" gate.
        guard text.count > scheme.count,
              let url = SafeURL(text.lowercased().hasPrefix("www.") ? "https://\(text)" : text) else {
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

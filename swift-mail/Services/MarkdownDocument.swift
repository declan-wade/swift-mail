//
//  MarkdownDocument.swift
//  swift-mail
//

import Foundation

/// Parses Markdown into a block tree for native SwiftUI rendering.
///
/// `AttributedString(markdown:)` is Foundation's own Markdown SDK (cmark-gfm
/// under the hood), but it only goes half the way to a preview: SwiftUI's
/// `Text` renders `InlinePresentationIntent` (bold, italic, code, strikethrough,
/// links) automatically, and completely ignores `PresentationIntent` — the
/// block-level structure (headings, lists, quotes, code fences, tables) is
/// there in the parsed runs, but nothing lays it out. This type walks the
/// runs, reconstructs that structure from each run's `PresentationIntent`, and
/// hands back a tree `MarkdownPreview` can draw.
///
/// A run's `PresentationIntent.components` is its full ancestor chain,
/// **innermost first** — a paragraph inside a list item inside a list reports
/// `[.paragraph, .listItem, .unorderedList]` — so building the tree means
/// walking each run's chain in reverse and re-attaching by `identity`, the
/// stable id every intent in the same structural block shares.
nonisolated enum MarkdownDocument {
    /// A laid-out block, ready for `MarkdownPreview` to draw.
    indirect enum Block: Identifiable {
        case paragraph(AttributedString, id: Int)
        case heading(AttributedString, level: Int, id: Int)
        case list(items: [[Block]], isOrdered: Bool, start: Int, id: Int)
        case blockQuote(children: [Block], id: Int)
        case codeBlock(text: String, language: String?, id: Int)
        case thematicBreak(id: Int)
        case table(columnCount: Int, headers: [AttributedString], rows: [[AttributedString]], id: Int)

        var id: Int {
            switch self {
            case .paragraph(_, let id),
                 .heading(_, _, let id),
                 .list(_, _, _, let id),
                 .blockQuote(_, let id),
                 .codeBlock(_, _, let id),
                 .thematicBreak(let id),
                 .table(_, _, _, let id):
                return id
            }
        }
    }

    static func parse(_ markdown: String) -> [Block] {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard var attributed = try? AttributedString(markdown: markdown, options: options) else {
            return [.paragraph(AttributedString(markdown), id: 0)]
        }

        sanitizeLinks(in: &attributed)
        return Tree(from: attributed).topLevelBlocks()
    }

    /// Mirrors `MarkdownRenderer.SafeURL`'s scheme allow-list so a pasted
    /// `javascript:` link can't ride along in the native preview either — see
    /// that type's doc comment for why an explicit allow-list is required.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    private static func sanitizeLinks(in attributed: inout AttributedString) {
        for run in attributed.runs {
            if let url = run.link, !allowedLinkSchemes.contains(url.scheme?.lowercased() ?? "") {
                attributed[run.range].link = nil
            }
        }
    }
}

// MARK: - Tree construction

/// Rebuilds nesting from each run's flattened, innermost-first
/// `PresentationIntent.components` list by keying a node graph on
/// `identity` — every run belonging to the same structural block (the two
/// lines of one loose list item, every cell in one table) reports the same
/// identity for that level, which is what lets runs re-join their block
/// instead of each starting a new one.
private final class Tree {
    private final class Node {
        /// `nil` only for the synthetic document root.
        let kind: PresentationIntent.Kind?
        let identity: Int
        var children: [Node] = []
        var content = AttributedString()

        init(kind: PresentationIntent.Kind?, identity: Int) {
            self.kind = kind
            self.identity = identity
        }
    }

    private var nodesByIdentity: [Int: Node] = [:]
    private let root = Node(kind: nil, identity: -1)

    init(from attributed: AttributedString) {
        for run in attributed.runs {
            let slice = AttributedString(attributed[run.range])

            guard let intent = run.presentationIntent, !intent.components.isEmpty else {
                root.content.append(slice)
                continue
            }

            var parent = root
            for component in intent.components.reversed() {
                if let existing = nodesByIdentity[component.identity] {
                    parent = existing
                    continue
                }

                let node = Node(kind: component.kind, identity: component.identity)
                nodesByIdentity[component.identity] = node
                parent.children.append(node)
                parent = node
            }

            parent.content.append(slice)
        }
    }

    func topLevelBlocks() -> [MarkdownDocument.Block] {
        root.children.map(Self.block(for:))
    }

    private static func block(for node: Node) -> MarkdownDocument.Block {
        let id = node.identity

        switch node.kind {
        case .header(let level):
            return .heading(node.content, level: level, id: id)

        case .codeBlock(let languageHint):
            return .codeBlock(text: String(node.content.characters), language: languageHint, id: id)

        case .thematicBreak:
            return .thematicBreak(id: id)

        case .blockQuote:
            return .blockQuote(children: node.children.map(block(for:)), id: id)

        case .orderedList, .unorderedList:
            let isOrdered = node.kind == .orderedList
            let start = node.children.first.flatMap(ordinal) ?? 1
            let items = node.children.map { $0.children.map(block(for:)) }
            return .list(items: items, isOrdered: isOrdered, start: start, id: id)

        case .table:
            return tableBlock(for: node, id: id)

        case .paragraph, .listItem, .tableCell, .tableRow, .tableHeaderRow, nil:
            // A list item / table row-or-cell is a pure grouping node here —
            // its own case is handled by the parent that iterates
            // `node.children` directly, so reaching this branch means either a
            // plain paragraph or a shape not otherwise recognized. Either way
            // the accumulated inline content is the useful part.
            return .paragraph(node.content, id: id)

        @unknown default:
            return .paragraph(node.content, id: id)
        }
    }

    private static func ordinal(for node: Node) -> Int? {
        guard case .listItem(let ordinal) = node.kind else {
            return nil
        }
        return ordinal
    }

    private static func tableBlock(for node: Node, id: Int) -> MarkdownDocument.Block {
        let columnCount: Int
        if case .table(let columns) = node.kind {
            columnCount = columns.count
        } else {
            columnCount = node.children.first?.children.count ?? 0
        }

        func cells(of rowNode: Node) -> [AttributedString] {
            rowNode.children
                .sorted { columnIndex(of: $0) < columnIndex(of: $1) }
                .map(\.content)
        }

        var headers: [AttributedString] = []
        var rows: [[AttributedString]] = []

        for rowNode in node.children {
            switch rowNode.kind {
            case .tableHeaderRow:
                headers = cells(of: rowNode)
            case .tableRow:
                rows.append(cells(of: rowNode))
            default:
                continue
            }
        }

        return .table(columnCount: columnCount, headers: headers, rows: rows, id: id)
    }

    private static func columnIndex(of node: Node) -> Int {
        guard case .tableCell(let columnIndex) = node.kind else {
            return 0
        }
        return columnIndex
    }
}

//
//  MarkdownPreview.swift
//  swift-mail
//

import SwiftUI

/// A live, native rendering of a Markdown draft.
///
/// This is the "Preview" mode in compose — real SwiftUI text (selectable,
/// theme-aware, no `WKWebView`), built from `MarkdownDocument`'s block tree.
/// The companion "As Recipient Sees It" mode renders the same source through
/// `MarkdownRenderer` + `HTMLMessageView` instead, showing the actual HTML
/// that ships — the two intentionally look slightly different, because they
/// are answering different questions.
struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        ScrollView {
            let blocks = MarkdownDocument.parse(markdown)

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if blocks.isEmpty {
                    Text("Nothing to preview yet.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(blocks) { block in
                        MarkdownBlockView(block: block)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(Theme.Spacing.xxl)
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block

    var body: some View {
        switch block {
        case .paragraph(let text, _):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let text, let level, _):
            Text(text)
                .font(Self.headingFont(level: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? Theme.Spacing.xs : 0)

        case .thematicBreak:
            Divider()

        case .blockQuote(let children, _):
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(children) { MarkdownBlockView(block: $0) }
                }
                .foregroundStyle(.secondary)
            }

        case .codeBlock(let text, _, _):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
            }
            .padding(Theme.Spacing.sm)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))

        case .list(let items, let isOrdered, let start, _):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(isOrdered ? "\(start + offset)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)

                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(item) { MarkdownBlockView(block: $0) }
                        }
                    }
                }
            }

        case .table(let columnCount, let headers, let rows, _):
            Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            Text(headers[column]).fontWeight(.semibold)
                        }
                    }

                    Divider().gridCellColumns(columnCount)
                }

                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(rows[rowIndex].indices.contains(column) ? rows[rowIndex][column] : AttributedString())
                        }
                    }
                }
            }
        }
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}

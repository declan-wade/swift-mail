import AppKit
import SwiftUI

/// The Markdown body editor.
///
/// This wraps `NSTextView` rather than using `TextEditor` because a
/// Markdown-first composer needs things SwiftUI does not expose: smart quotes and
/// dash substitution have to be off (they corrupt `--`, `"`, and code spans),
/// and list continuation and the formatting shortcuts need first-responder access.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.string = text

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.drawsBackground = false

        // Substitutions rewrite the characters Markdown is made of, so they stay off.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true

        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
            return
        }

        let selection = textView.selectedRange()
        textView.string = text
        textView.setSelectedRange(NSRange(
            location: min(selection.location, (text as NSString).length),
            length: 0
        ))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text.wrappedValue = textView.string
        }
    }
}

/// An `NSTextView` that understands the Markdown it is holding.
final class MarkdownTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch (key, modifiers.contains(.shift)) {
        case ("b", false):
            wrapSelection(with: "**")
        case ("i", false):
            wrapSelection(with: "_")
        case ("c", true):
            wrapSelection(with: "`")
        case ("x", true):
            wrapSelection(with: "~~")
        case ("k", false):
            insertLink()
        default:
            return super.performKeyEquivalent(with: event)
        }

        return true
    }

    /// Continues list and blockquote prefixes, and ends the list when Return is
    /// pressed on an item that was left empty.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0 else {
            super.insertNewline(sender)
            return
        }

        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)

        guard let prefix = MarkdownLinePrefix(line: line) else {
            super.insertNewline(sender)
            return
        }

        if prefix.hasEmptyContent {
            let clearRange = NSRange(location: lineRange.location, length: (line as NSString).length)
            replaceCharacters(
                in: clearRange,
                with: "",
                selecting: NSRange(location: lineRange.location, length: 0)
            )
            super.insertNewline(sender)
            return
        }

        super.insertNewline(sender)
        insertText(prefix.continuation, replacementRange: selectedRange())
    }

    /// Wraps or unwraps the selection, so the shortcut toggles rather than piles
    /// delimiters on top of each other.
    private func wrapSelection(with delimiter: String) {
        let range = selectedRange()
        let text = string as NSString
        let selected = text.substring(with: range)
        let delimiterLength = (delimiter as NSString).length

        // Already wrapped inside the selection.
        if selected.count >= delimiter.count * 2, selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
            let unwrapped = String(selected.dropFirst(delimiter.count).dropLast(delimiter.count))
            replaceCharacters(
                in: range,
                with: unwrapped,
                selecting: NSRange(location: range.location, length: (unwrapped as NSString).length)
            )
            return
        }

        // Already wrapped just outside the selection.
        let outer = NSRange(
            location: range.location - delimiterLength,
            length: range.length + delimiterLength * 2
        )
        if outer.location >= 0, NSMaxRange(outer) <= text.length {
            let surrounding = text.substring(with: outer)
            if surrounding.hasPrefix(delimiter), surrounding.hasSuffix(delimiter) {
                replaceCharacters(
                    in: outer,
                    with: selected,
                    selecting: NSRange(location: outer.location, length: range.length)
                )
                return
            }
        }

        let wrapped = delimiter + selected + delimiter
        let selection = range.length == 0
            ? NSRange(location: range.location + delimiterLength, length: 0)
            : NSRange(location: range.location, length: (wrapped as NSString).length)

        replaceCharacters(in: range, with: wrapped, selecting: selection)
    }

    private func insertLink() {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        let selectedIsURL = selected.hasPrefix("http://") || selected.hasPrefix("https://")

        // A selected URL becomes the destination and the cursor lands on the label;
        // selected prose becomes the label and the cursor lands on the destination.
        let replacement = selectedIsURL ? "[](\(selected))" : "[\(selected)](url)"
        let selection = selectedIsURL
            ? NSRange(location: range.location + 1, length: 0)
            : NSRange(location: range.location + (selected as NSString).length + 3, length: 3)

        replaceCharacters(in: range, with: replacement, selecting: selection)
    }

    /// Edits through the text storage so every change lands on the undo stack and
    /// notifies the delegate, which is what keeps the SwiftUI binding in sync.
    private func replaceCharacters(in range: NSRange, with replacement: String, selecting selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else {
            return
        }

        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
    }
}

/// The list, ordered-list, or blockquote prefix on a line being edited.
private struct MarkdownLinePrefix {
    let continuation: String
    let hasEmptyContent: Bool

    init?(line: String) {
        let indentCount = line.prefix { $0 == " " || $0 == "\t" }.count
        let indent = String(line.prefix(indentCount))
        let rest = line.dropFirst(indentCount)

        if rest.hasPrefix("> ") || rest == ">" {
            continuation = "\(indent)> "
            hasEmptyContent = rest.dropFirst(1).trimmingCharacters(in: .whitespaces).isEmpty
            return
        }

        if let bullet = rest.first, bullet == "-" || bullet == "*" || bullet == "+" {
            let afterMarker = rest.dropFirst()
            guard afterMarker.first == " " else {
                return nil
            }

            // Preserve task-list items as unchecked boxes.
            let content = afterMarker.dropFirst().trimmingCharacters(in: .whitespaces)
            let isTask = content.hasPrefix("[ ] ") || content.hasPrefix("[x] ") || content.hasPrefix("[X] ")

            continuation = isTask ? "\(indent)\(bullet) [ ] " : "\(indent)\(bullet) "
            hasEmptyContent = isTask
                ? String(content.dropFirst(4)).trimmingCharacters(in: .whitespaces).isEmpty
                : content.isEmpty
            return
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else {
            return nil
        }

        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else {
            return nil
        }

        continuation = "\(indent)\(number + 1)\(delimiter) "
        hasEmptyContent = afterDigits.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
    }
}

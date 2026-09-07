import AppKit
import SwiftUI

/// A recipient field backed by `NSTokenField`.
///
/// AppKit already does the fiddly parts natively — comma tokenizing, token
/// editing, drag and drop — and the token style doubles as validation: an entry
/// that does not parse as an address stays plain text instead of becoming a chip.
struct RecipientField: NSViewRepresentable {
    @Binding var addresses: [EmailAddress]
    var placeholder: String

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.objectValue = addresses.map(\.editableText)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.addresses = $addresses

        // Never rewrite the field while it holds an entry in progress.
        guard field.currentEditor() == nil else {
            return
        }

        let current = Coordinator.parse(field.objectValue)
        guard current != addresses else {
            return
        }

        field.objectValue = addresses.map(\.editableText)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(addresses: $addresses)
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var addresses: Binding<[EmailAddress]>

        init(addresses: Binding<[EmailAddress]>) {
            self.addresses = addresses
        }

        static func parse(_ objectValue: Any?) -> [EmailAddress] {
            guard let entries = objectValue as? [Any] else {
                return []
            }

            return entries
                .compactMap { $0 as? String }
                .compactMap(EmailAddress.init(entry:))
        }

        /// Tokens show the friendly name; the full `Name <address>` form appears
        /// only while the token is being edited.
        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            guard let entry = representedObject as? String else {
                return nil
            }

            guard let address = EmailAddress(entry: entry) else {
                return entry
            }

            return address.name?.nilIfEmpty ?? address.email
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            representedObject as? String
        }

        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
            guard let entry = representedObject as? String, EmailAddress(entry: entry) != nil else {
                return .none
            }

            return .rounded
        }

        func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
            false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            commit(notification.object as? NSTokenField)
        }

        func controlTextDidChange(_ notification: Notification) {
            commit(notification.object as? NSTokenField)
        }

        private func commit(_ field: NSTokenField?) {
            guard let field else {
                return
            }

            let parsed = Self.parse(field.objectValue)
            guard parsed != addresses.wrappedValue else {
                return
            }

            addresses.wrappedValue = parsed
        }
    }
}

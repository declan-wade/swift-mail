import SwiftUI

/// An action bindable to either edge of a message row's swipe. Each case maps
/// onto a `MailStore` method the toolbar and context menu already call, so a
/// swipe is another way to reach the same action, not a parallel one.
nonisolated enum SwipeAction: String, CaseIterable, Identifiable {
    case none
    case toggleRead
    case flag
    case archive
    case delete

    var id: String { rawValue }

    /// Shown in the Settings picker, where there is no message to be specific
    /// about. The swipe itself uses `label(for:)`.
    var settingsLabel: String {
        switch self {
        case .none: "Nothing"
        case .toggleRead: "Mark as Read / Unread"
        case .flag: "Flag / Unflag"
        case .archive: "Archive"
        case .delete: "Delete"
        }
    }

    /// Reads the message's current state, so the swipe says what it will do
    /// rather than naming a mode the message is already in.
    func label(for email: EmailPreview) -> String {
        switch self {
        case .none: ""
        case .toggleRead: email.isUnread ? "Read" : "Unread"
        case .flag: email.isFlagged ? "Unflag" : "Flag"
        case .archive: "Archive"
        case .delete: "Delete"
        }
    }

    func icon(for email: EmailPreview) -> String {
        switch self {
        case .none: ""
        case .toggleRead: email.isUnread ? "envelope.open" : "envelope.badge"
        case .flag: email.isFlagged ? "flag.slash" : "flag"
        case .archive: "archivebox"
        case .delete: "trash"
        }
    }

    var tint: Color {
        switch self {
        case .none: .clear
        case .toggleRead: .blue
        case .flag: .orange
        case .archive: .indigo
        case .delete: .red
        }
    }

    func perform(on email: EmailPreview, in store: MailStore) async {
        switch self {
        case .none: break
        case .toggleRead: await store.toggleReadState(emailID: email.id)
        case .flag: await store.toggleFlag(emailID: email.id)
        case .archive: await store.archive(emailID: email.id)
        case .delete: await store.delete(emailID: email.id)
        }
    }
}

nonisolated enum SwipePreferences {
    static let leadingKey = "swift-mail.swipe.leading"
    static let trailingKey = "swift-mail.swipe.trailing"

    /// Left-to-right reveals the reversible action, right-to-left the one that
    /// moves the message out of the list — the arrangement Mail uses.
    static let leadingDefault = SwipeAction.toggleRead
    static let trailingDefault = SwipeAction.archive
}

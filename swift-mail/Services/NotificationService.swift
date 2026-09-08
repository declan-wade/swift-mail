import Foundation
import AppKit
import UserNotifications

/// Local delivery of new-mail notifications, plus the notification actions the
/// user can take from Notification Center without bringing the app forward.
///
/// A single shared instance is installed as the `UNUserNotificationCenter`
/// delegate at launch (see `AppDelegate`), which is what lets a notification
/// that *launches* the app be handled. `MailStore` sets `actionHandler` once it
/// exists so taps and action buttons route back into the model.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// What the user asked for from a delivered notification.
    enum Action {
        /// Default action — the notification body was tapped.
        case open(emailID: String)
        case markRead(emailID: String)
        case archive(emailID: String)
        case trash(emailID: String)
    }

    var actionHandler: ((Action) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false

    private enum Category {
        static let newEmail = "NEW_EMAIL"
    }

    private enum ActionID {
        static let markRead = "MARK_READ"
        static let archive = "ARCHIVE"
        static let trash = "TRASH"
    }

    private static let identifierPrefix = "new-message-"

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let markRead = UNNotificationAction(
            identifier: ActionID.markRead,
            title: "Mark as Read",
            options: []
        )
        let archive = UNNotificationAction(
            identifier: ActionID.archive,
            title: "Archive",
            options: []
        )
        let trash = UNNotificationAction(
            identifier: ActionID.trash,
            title: "Trash",
            options: [.destructive]
        )

        let newEmail = UNNotificationCategory(
            identifier: Category.newEmail,
            actions: [markRead, archive, trash],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([newEmail])
    }

    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else {
            return
        }

        hasRequestedAuthorization = true

        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Notification permission errors should not block mail sync.
        }
    }

    /// Posts one notification per newly arrived message (capped), grouped in
    /// Notification Center by conversation.
    func notifyNewMessages(_ messages: [EmailPreview], mailboxName: String) async {
        guard !messages.isEmpty else {
            return
        }

        await requestAuthorizationIfNeeded()

        guard await isAuthorized else {
            return
        }

        for message in messages.prefix(10) {
            let content = UNMutableNotificationContent()
            content.title = message.senderLine
            content.subtitle = message.subjectLine
            content.body = message.preview?.nilIfEmpty ?? ""
            content.sound = .default
            content.categoryIdentifier = Category.newEmail
            content.threadIdentifier = message.threadId ?? message.from?.first?.email ?? mailboxName
            content.targetContentIdentifier = message.id
            content.userInfo = ["emailID": message.id]
            content.interruptionLevel = .active

            let request = UNNotificationRequest(
                identifier: Self.identifierPrefix + message.id,
                content: content,
                trigger: nil
            )

            try? await center.add(request)
        }
    }

    /// Withdraws the notifications for messages that are no longer new — read in
    /// the app, or read/moved on another device.
    func clearNotifications(for emailIDs: [String]) {
        guard !emailIDs.isEmpty else {
            return
        }

        let identifiers = emailIDs.map { Self.identifierPrefix + $0 }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The dock badge is managed from the unread count, not per-notification.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let emailID = userInfo["emailID"] as? String else {
            return
        }

        let action: Action?
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            action = .open(emailID: emailID)
        case ActionID.markRead:
            action = .markRead(emailID: emailID)
        case ActionID.archive:
            action = .archive(emailID: emailID)
        case ActionID.trash:
            action = .trash(emailID: emailID)
        default:
            action = nil
        }

        guard let action else {
            return
        }

        await MainActor.run {
            if case .open = action {
                NSApp.activate(ignoringOtherApps: true)
            }
            actionHandler?(action)
        }
    }
}

import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else {
            return
        }

        hasRequestedAuthorization = true

        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Notification permission errors should not block mail refresh.
        }
    }

    func notifyNewMessages(_ messages: [EmailPreview], mailboxName: String) async {
        guard !messages.isEmpty else {
            return
        }

        await requestAuthorizationIfNeeded()

        for message in messages.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = message.senderLine
            content.subtitle = mailboxName
            content.body = message.subjectLine
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "new-message-\(message.id)",
                content: content,
                trigger: nil
            )

            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

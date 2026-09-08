//
//  swift_mailApp.swift
//  swift-mail
//
//  Created by Declan Wade on 3/6/2026.
//

import SwiftUI
import UserNotifications

@main
struct swift_mailApp: App {
    /// The store lives at the app level so compose windows can send without being
    /// children of the main window.
    @StateObject private var store = MailStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .commands {
            ComposeCommands(store: store)
        }

        WindowGroup(id: ComposeWindow.id, for: ComposeDraft.self) { $draft in
            ComposeView(store: store, draft: draft ?? .blank(identity: store.defaultIdentity))
        }
        .defaultSize(width: 760, height: 620)
    }
}

/// Installs the notification-center delegate before the app finishes launching,
/// so a notification the user acted on to *open* the app is delivered to us.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NotificationService.shared
    }
}

private struct ComposeCommands: Commands {
    @ObservedObject var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                openWindow(id: ComposeWindow.id, value: ComposeDraft.blank(identity: store.defaultIdentity))
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

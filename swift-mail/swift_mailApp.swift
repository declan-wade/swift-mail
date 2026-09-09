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
                // The delegate needs the store to answer the quit prompt, and
                // this is the one place both are in scope.
                .onAppear { appDelegate.store = store }
        }
        .commands {
            ComposeCommands(store: store)
        }

        WindowGroup(id: ComposeWindow.id, for: ComposeDraft.self) { $draft in
            ComposeView(store: store, draft: draft ?? .blank(identity: store.defaultIdentity))
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView(store: store)
        }
    }
}

/// Installs the notification-center delegate before the app finishes launching,
/// so a notification the user acted on to *open* the app is delivered to us.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Weak: the store belongs to the `App`, which outlives this anyway.
    weak var store: MailStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NotificationService.shared
    }

    /// Warns before quitting while a message is still recallable.
    ///
    /// Not because quitting would stop the send — the server is holding the
    /// message and will release it whether or not this app is running — but
    /// because the undo is the one part that lives only here. Quitting spends
    /// it silently otherwise.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pending = store?.pendingSend else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "\u{201C}\(pending.subject)\u{201D} hasn't sent yet"
        alert.informativeText = "It sends \(pending.releaseDescription()). Quitting won't stop that "
            + "— the server is holding the message, not this app — but you'll lose the chance to undo it."

        // Cancel first, so it takes Return: an alert that exists to make
        // someone read it is defeated by a default button that dismisses it.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")

        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
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

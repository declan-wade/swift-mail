import SwiftUI

/// The Settings window, split the way macOS expects: a small number of
/// noun-named tabs, each pane a grouped `Form` at a shared width so the window
/// only ever changes height between tabs.
struct SettingsView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }

            Tab("Notifications", systemImage: "bell") {
                NotificationSettings(store: store)
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedSettings(store: store)
            }
        }
        .frame(width: SettingsPane.width)
    }
}

/// Shared pane geometry. A Settings window isn't user-resizable, so the width
/// is fixed once here and each pane states only its own height.
private enum SettingsPane {
    static let width: CGFloat = 480
}

private extension View {
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped).frame(width: SettingsPane.width, height: height)
    }
}

// MARK: - General

/// How a message behaves when you read it or swipe it.
private struct GeneralSettings: View {
    @AppStorage(ReadingPreferences.marksReadOnOpenKey) private var marksReadOnOpen = false
    @AppStorage(SwipePreferences.leadingKey) private var leadingSwipe = SwipePreferences.leadingDefault.rawValue
    @AppStorage(SwipePreferences.trailingKey) private var trailingSwipe = SwipePreferences.trailingDefault.rawValue

    var body: some View {
        Form {
            Section("Reading") {
                Picker("Mark messages as read", selection: $marksReadOnOpen) {
                    Text("When I click Mark as Read").tag(false)
                    Text("When I open the message").tag(true)
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                Picker("Swipe right", selection: $leadingSwipe) {
                    swipeOptions
                }

                Picker("Swipe left", selection: $trailingSwipe) {
                    swipeOptions
                }
            } header: {
                Text("Swipe Actions")
            } footer: {
                Text("Two-finger swipe across a message in the list. Swipe right reveals the action on the left edge, swipe left the one on the right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane(height: 330)
    }

    @ViewBuilder
    private var swipeOptions: some View {
        ForEach(SwipeAction.allCases) { action in
            Text(action.settingsLabel).tag(action.rawValue)
        }
    }
}

// MARK: - Notifications

/// Fastmail's server-side rules file mail into folders before the client ever
/// sees it, and JMAP carries no per-mailbox "notify me" flag, so the choice
/// lives here instead of on the server.
private struct NotificationSettings: View {
    @ObservedObject var store: MailStore
    @AppStorage(NotifyingMailboxes.storageKey) private var notifyingList = ""

    var body: some View {
        Form {
            Section {
                if store.mailboxes.isEmpty {
                    Text("Connect an account to choose folders.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.mailboxes) { mailbox in
                        Toggle(isOn: binding(for: mailbox)) {
                            Label(mailbox.displayName, systemImage: mailbox.iconName)
                        }
                    }
                }
            } header: {
                Text("Notify me about new mail in")
            } footer: {
                Text("Server rules can file mail straight into a folder without it ever reaching the Inbox. Switch that folder on to be notified anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Taller than the others on purpose: this is a list of every folder,
        // and it scrolls inside the pane rather than growing the window.
        .settingsPane(height: 460)
    }

    private func binding(for mailbox: Mailbox) -> Binding<Bool> {
        Binding(
            get: { NotifyingMailboxes.ids(in: notifyingList).contains(mailbox.id) },
            set: { isOn in
                var ids = NotifyingMailboxes.ids(in: notifyingList)
                if isOn {
                    ids.insert(mailbox.id)
                } else {
                    ids.remove(mailbox.id)
                }

                notifyingList = NotifyingMailboxes.list(from: ids)
            }
        )
    }
}

// MARK: - Advanced

/// Read-only diagnostics about the connected server: what it implements, what
/// this account may actually use, and the limits it will accept.
private struct AdvancedSettings: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Form {
            Section {
                urns(store.serverCapabilities, empty: "Connect an account to see what the server supports.")
            } header: {
                Text("Server Capabilities")
            } footer: {
                Text("The JMAP extensions this server implements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                urns(store.accountCapabilities, empty: "None advertised for this account.")
            } header: {
                Text("Account Capabilities")
            } footer: {
                Text("What this account may actually use. A server can implement a feature without granting it here — this is the list that decides whether a method call will work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !store.serverLimits.isEmpty {
                Section("Limits") {
                    ForEach(store.serverLimits, id: \.label) { limit in
                        LabeledContent(limit.label, value: limit.value)
                    }
                }
            }

            Section("Features") {
                LabeledContent("Snooze", value: store.supportsSnooze ? "Available" : "Not available")
            }
        }
        // Diagnostics run long; the tail scrolls rather than making the
        // window taller than the other panes by half again.
        .settingsPane(height: 520)
    }

    @ViewBuilder
    private func urns(_ list: [String], empty: String) -> some View {
        if list.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            ForEach(list, id: \.self) { urn in
                Text(urn)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

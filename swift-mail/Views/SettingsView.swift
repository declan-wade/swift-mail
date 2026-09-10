import SwiftUI
import AppKit

/// The Settings window, split the way macOS expects: a small number of
/// noun-named tabs, each pane a grouped `Form` at a shared width so the window
/// only ever changes height between tabs.
struct SettingsView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(store: store)
            }

            Tab("Tags", systemImage: "tag") {
                TagSettings(store: store)
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
    @ObservedObject var store: MailStore
    @AppStorage(SendPreferences.undoDelayKey) private var undoDelay = 0
    @AppStorage(ReadingPreferences.marksReadOnOpenKey) private var marksReadOnOpen = false
    @AppStorage(SwipePreferences.leadingKey) private var leadingSwipe = SwipePreferences.leadingDefault.rawValue
    @AppStorage(SwipePreferences.trailingKey) private var trailingSwipe = SwipePreferences.trailingDefault.rawValue
    @AppStorage(DownloadPreferences.bookmarkKey) private var downloadBookmark: Data?

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
                Picker("Delay sending by", selection: $undoDelay) {
                    ForEach(SendPreferences.undoDelayChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Don't delay" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(!store.supportsDelayedSend)
            } header: {
                Text("Sending")
            } footer: {
                Text(store.supportsDelayedSend
                     ? "The server holds the message for this long before releasing it, and it can be recalled until then. The hold is the server's, so it survives quitting the app."
                     : "This account's server won't hold outgoing mail, so messages send immediately and can't be recalled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Save attachments to") {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(DownloadPreferences.folderName(from: downloadBookmark))
                            .foregroundStyle(.secondary)

                        Button("Choose\u{2026}", action: chooseDownloadFolder)

                        // Only offered once it would do something: the sandbox
                        // grants ~/Downloads outright, so going back to it is
                        // dropping the bookmark rather than picking a folder.
                        if downloadBookmark != nil {
                            Button("Use Downloads") {
                                DownloadPreferences.useDefaultFolder()
                            }
                        }
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Anywhere outside Downloads has to be picked here once, so the app is granted access to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .settingsPane(height: 600)
    }

    /// The open panel is the grant: picking a folder is what lets the sandbox
    /// write to it, and the bookmark is what makes that survive a relaunch.
    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where saved attachments go."
        panel.directoryURL = DownloadPreferences.resolvedFolder() ?? .downloadsDirectory

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try DownloadPreferences.setFolder(url)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var swipeOptions: some View {
        ForEach(SwipeAction.allCases) { action in
            Text(action.settingsLabel).tag(action.rawValue)
        }
    }
}

// MARK: - Tags

/// Which alias belongs to which tag.
///
/// An address belongs to one tag at a time, so this asks the question once per
/// alias — "what kind of mail is this address for" — instead of offering a
/// checklist per tag that could contradict itself.
private struct TagSettings: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Form {
            Section {
                if store.tags.isEmpty {
                    Text("No tags yet. Messages carry no labels and every folder shows all of your mail.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($store.tags) { $tag in
                        TagRow(tag: $tag) { store.removeTag(id: tag.id) }
                    }
                }

                Button("Add Tag", systemImage: "plus") {
                    store.addTag()
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("A tag colours its mail in the message list. Pick one in the sidebar to narrow every folder to just that tag's mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.tags.isEmpty {
                    Text("Add a tag first, then assign your addresses to it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.taggableAddresses, id: \.self) { address in
                        Picker(address, selection: tagBinding(for: address)) {
                            Text("None").tag(MailTag.ID?.none)

                            ForEach(store.tags) { tag in
                                Text(tag.displayName).tag(MailTag.ID?.some(tag.id))
                            }
                        }
                    }

                    AddAddressRow(tags: store.tags) { address, tagID in
                        store.assignAddress(address, toTagID: tagID)
                    }
                }
            } header: {
                Text("Addresses")
            } footer: {
                Text("A message takes the tag of the address it was sent to, or sent from — so Sent and Drafts sort the same way the Inbox does. Your sending identities are listed automatically; type anything else your mail arrives at, including an external Outlook, Gmail or SMTP account. A wildcard like *@example.com covers every address on that domain. Set an address to None to drop it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane(height: 560)
    }

    private func tagBinding(for address: String) -> Binding<MailTag.ID?> {
        Binding(
            // The same resolution the message list uses, so the pane can't
            // disagree with the chips about which tag an address belongs to.
            get: { store.tags.tag(forAddress: address)?.id },
            set: { store.assignAddress(address, toTagID: $0) }
        )
    }
}

/// Adds an address the account doesn't advertise as a sending identity.
///
/// The tag is chosen here rather than after the fact because an address that
/// belongs to no tag has nowhere to be stored — the assignment *is* the record
/// of the address.
private struct AddAddressRow: View {
    let tags: [MailTag]
    let onAdd: (String, MailTag.ID) -> Void

    @State private var text = ""
    @State private var tagID: MailTag.ID?

    private var normalized: String? {
        MailTag.normalizedAddress(text)
    }

    private var selectedTagID: MailTag.ID? {
        tagID ?? tags.first?.id
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Custom alias", text: $text, prompt: Text("Custom alias"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(add)

            Picker("Tag", selection: Binding(get: { selectedTagID }, set: { tagID = $0 })) {
                ForEach(tags) { tag in
                    Text(tag.displayName).tag(MailTag.ID?.some(tag.id))
                }
            }
            .labelsHidden()
            .fixedSize()

            Button("Add", action: add)
                .disabled(normalized == nil || selectedTagID == nil)
        }
    }

    private func add() {
        guard let normalized, let selectedTagID else {
            return
        }

        onAdd(normalized, selectedTagID)
        text = ""
    }
}

/// One tag: its colour, its name, and the way to remove it. Removing a tag
/// also releases the aliases assigned to it, because the assignment is stored
/// on the tag itself rather than beside it.
private struct TagRow: View {
    @Binding var tag: MailTag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(tag.color.color)
                .frame(width: Theme.Size.unreadDot + 2, height: Theme.Size.unreadDot + 2)

            // Hiding the label is what widens the field: a `Form` otherwise
            // spends the leading column on the title and right-aligns what's
            // left, which is why the names sat hard against the colour picker.
            TextField("Tag name", text: $tag.name, prompt: Text("Tag name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)

            Picker("Colour", selection: $tag.color) {
                ForEach(TagColor.allCases) { color in
                    Text(color.label).tag(color)
                }
            }
            .labelsHidden()
            .fixedSize()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove Tag")
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
                LabeledContent(
                    "Delayed send",
                    value: store.supportsDelayedSend
                        ? "Up to \(Duration.seconds(store.maxDelayedSend).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))"
                        : "Not available"
                )
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

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

            Tab("Snooze", systemImage: "moon.zzz") {
                SnoozeSettings()
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
    @AppStorage(IntelligencePreferences.threadSummariesOffKey) private var threadSummariesOff = false
    @AppStorage(SenderWarningPreferences.impersonationOffKey) private var impersonationWarningsOff = false
    @AppStorage(IntelligencePreferences.messageTriageOffKey) private var messageTriageOff = false
    @AppStorage(ComposePreferences.inlineKey) private var composesInline = false

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
                Toggle("Summarise long threads", isOn: Binding(
                    get: { !threadSummariesOff },
                    set: { threadSummariesOff = !$0 }
                ))
                .disabled(!IntelligenceStatus.isSupportedOnThisMac)

                Toggle("Flag messages that look like scams", isOn: Binding(
                    get: { !messageTriageOff },
                    set: { messageTriageOff = !$0 }
                ))
                .disabled(!IntelligenceStatus.isSupportedOnThisMac)
            } header: {
                Text("Apple Intelligence")
            } footer: {
                // The model's own state is worth surfacing here: the toggle
                // can be on while the feature still can't run, and Settings is
                // where someone goes to find out why.
                Text(intelligenceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Warn about impersonated senders", isOn: Binding(
                    get: { !impersonationWarningsOff },
                    set: { impersonationWarningsOff = !$0 }
                ))
            } header: {
                Text("Sender Warnings")
            } footer: {
                Text("Shows a warning when a message's name claims a brand — myGov, ANZ, PayPal — that the sending domain doesn't belong to. It never files anything on its own. This is a check against a list of known sending domains, not Apple Intelligence, so it works either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("New messages open", selection: $composesInline) {
                    Text("In a separate window").tag(false)
                    Text("In the reading pane").tag(true)
                }
            } header: {
                Text("Composing")
            } footer: {
                Text("In the reading pane, a message being written replaces the one being read, and a button on its bar moves it out into a window at any time. A second message started while the pane is busy opens in a window either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .settingsPane(height: 760)
    }

    /// What the Apple Intelligence section says under its toggle.
    private var intelligenceFooter: String {
        let base = "Threads of \(ThreadSummarizer.minimumMessages) or more messages get a short summary at the top of the reader. Scam flagging reads unfiled mail from senders you’ve never written to, and only ever suggests — it never files anything. Both run on this Mac; no part of a message is sent anywhere."

        guard IntelligenceStatus.isSupportedOnThisMac else {
            return "This Mac doesn’t support Apple Intelligence, so thread summaries aren’t available."
        }

        guard let advice = IntelligenceStatus.currentAdvice else {
            return base
        }

        return "\(base)\n\n\(advice)"
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

// MARK: - Snooze

/// The times the Snooze menu offers, in the order it offers them.
private struct SnoozeSettings: View {
    @AppStorage(SnoozePreferences.presetsKey) private var presetData: Data?

    private var presets: Binding<[SnoozePreset]> {
        Binding(
            get: { SnoozePreferences.presets(from: presetData) },
            set: { presetData = SnoozePreferences.data(for: $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(presets.wrappedValue.enumerated()), id: \.element.id) { index, preset in
                    SnoozePresetRow(
                        preset: presets[index],
                        canMoveUp: index > 0,
                        onMoveUp: { presets.wrappedValue.swapAt(index, index - 1) },
                        onRemove: { presets.wrappedValue.remove(at: index) }
                    )
                }

                HStack {
                    Button("Add Time") {
                        presets.wrappedValue.append(SnoozePreset(kind: .tomorrow, hour: 8))
                    }

                    Spacer()

                    // Only offered once there is something to restore.
                    if presetData != nil {
                        Button("Restore Defaults") {
                            presetData = nil
                        }
                    }
                }
            } header: {
                Text("Snooze Times")
            } footer: {
                Text("The Snooze menu lists these in this order, with Custom\u{2026} below them for anything else. Clicking the Snooze button itself uses the first one that's still ahead — a time already gone today is skipped until tomorrow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPane(height: 420)
    }
}

private struct SnoozePresetRow: View {
    @Binding var preset: SnoozePreset
    let canMoveUp: Bool
    let onMoveUp: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Picker("When", selection: $preset.kind) {
                ForEach(SnoozePreset.Kind.allCases) { kind in
                    Text(kind.settingsLabel).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()

            if preset.kind == .weekday {
                Picker("Day", selection: $preset.weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if preset.kind == .hoursLater {
                Stepper(preset.hour == 1 ? "1 hour" : "\(preset.hour) hours", value: $preset.hour, in: 1...72)
            } else {
                Picker("Time", selection: $preset.hour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(SnoozePreset.hourText(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Spacer()

            Button(action: onMoveUp) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            .help("Move Up")

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
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
    @AppStorage(IntelligencePreferences.threadSummariesOffKey) private var threadSummariesOff = false
    @AppStorage(IntelligencePreferences.messageTriageOffKey) private var advancedTriageOff = false
    @State private var selfTestResult: String?
    @State private var isSelfTesting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Model", value: IntelligenceStatus.availabilityDescription)
                LabeledContent("Language", value: IntelligenceStatus.localeDescription)
                LabeledContent("Context window", value: IntelligenceStatus.contextSizeDescription)
                LabeledContent("Thread summaries", value: threadSummariesOff ? "Off" : "On")
                LabeledContent("Scam flagging", value: advancedTriageOff ? "Off" : "On")
                LabeledContent("Known correspondents", value: "\(store.recipients.count) skipped")
                LabeledContent("Minimum thread length", value: "\(ThreadSummarizer.minimumMessages) messages")
                // The gate the reader actually hits: a thread has to be open
                // and long enough before any of the above matters.
                LabeledContent("Open thread", value: openThreadDescription)

                HStack {
                    Button("Run Test Summary") {
                        Task {
                            isSelfTesting = true
                            selfTestResult = await ThreadSummarizer.selfTest()
                            isSelfTesting = false
                        }
                    }
                    .disabled(isSelfTesting)

                    if isSelfTesting {
                        ProgressView().controlSize(.small)
                    }
                }

                if let selfTestResult {
                    Text(selfTestResult)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Every condition a thread summary depends on. Run Test Summary to put the model through the same path a thread takes, against a fixed three-message example — the conditions above can all look right and the generation still fail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    /// What the currently open conversation would contribute, which is the
    /// first thing to check when summaries "never fire": the model can be
    /// perfectly available and the open thread simply too short.
    private var openThreadDescription: String {
        let count = store.conversation.count

        guard count > 0 else {
            return "None open"
        }

        return ThreadSummarizer.qualifies(messageCount: count)
            ? "\(count) messages — qualifies"
            : "\(count) message\(count == 1 ? "" : "s") — below the threshold"
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

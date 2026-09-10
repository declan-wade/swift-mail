import AppKit
import SwiftUI

enum MaskedEmailWindow {
    static let id = "masked-email"
}

/// The masked-address manager.
///
/// A window of its own rather than a sheet on the mail window: making an
/// address is something you do *while* filling in a signup form in another
/// app, and a sheet would hold the mail window hostage while you did it.
struct MaskedEmailView: View {
    @ObservedObject var store: MailStore
    @State private var query = ""
    @State private var filter = MaskedEmailFilter.current
    @State private var isCreating = false
    /// The address just put on the clipboard, so the row can say so.
    @State private var copiedID: MaskedEmail.ID?

    private var visible: [MaskedEmail] {
        store.maskedEmails.filter { filter.includes($0) && $0.matches(query) }
    }

    var body: some View {
        Group {
            if !store.supportsMaskedEmail {
                unavailable
            } else if store.maskedEmails.isEmpty && store.isLoadingMaskedEmails {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Masked Email")
        .searchable(text: $query, prompt: "Search addresses, notes and sites")
        .toolbar { toolbar }
        .task {
            await store.loadMaskedEmails()
        }
        // Keyed on the address just copied, so copying a second one restarts
        // the countdown rather than letting the first one's timer clear it.
        .task(id: copiedID) {
            guard copiedID != nil else {
                return
            }

            try? await Task.sleep(for: .seconds(2))

            guard !Task.isCancelled else {
                return
            }

            copiedID = nil
        }
        .sheet(isPresented: $isCreating) {
            NewMaskedEmailSheet { forDomain, note, prefix in
                await create(forDomain: forDomain, note: note, prefix: prefix)
            }
        }
        .alert("Masked Email Error", isPresented: Binding(
            get: { store.maskedEmailErrorMessage != nil },
            set: { if !$0 { store.maskedEmailErrorMessage = nil } }
        )) {
            Button("OK") { store.maskedEmailErrorMessage = nil }
        } message: {
            Text(store.maskedEmailErrorMessage ?? "")
        }
    }

    private var list: some View {
        List(visible) { masked in
            MaskedEmailRow(
                masked: masked,
                justCopied: copiedID == masked.id,
                onCopy: { copy(masked) },
                onSetState: { state in
                    Task { await store.setMaskedEmailState(id: masked.id, to: state) }
                }
            )
        }
        .listStyle(.inset)
    }

    /// The state the account is in until the API token is reissued with the
    /// masked-email scope, so it says exactly that rather than "no addresses".
    private var unavailable: some View {
        ContentUnavailableView {
            Label("Masked Email Unavailable", systemImage: "lock.badge.clock")
        } description: {
            Text("This account's API token doesn't carry the Masked Email scope, so the server won't answer for it. Reissue the token in Fastmail with Masked Email enabled, then add it again in Settings.")
        } actions: {
            Button("Check Again") {
                Task { await store.loadMaskedEmails() }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(
                query.isEmpty ? "No Masked Addresses" : "No Matches",
                systemImage: query.isEmpty ? "theatermasks" : "magnifyingglass"
            )
        } description: {
            Text(emptyDescription)
        } actions: {
            if query.isEmpty {
                Button("New Masked Address") { isCreating = true }
            }
        }
    }

    private var emptyDescription: String {
        if !query.isEmpty {
            return "No address, note or site matches \u{201C}\(query)\u{201D}."
        }

        // Says which list is empty, so an empty "Deleted" doesn't read as
        // having lost every address.
        if filter != .current {
            return "No \(filter.label.lowercased()) addresses."
        }

        return "Masked addresses forward to your inbox and can be blocked one at a time, so a leak costs you one address rather than your real one."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            // A menu rather than the eye toggle this replaced: that one gave
            // no clue what it was hiding, and looked broken on an account with
            // nothing deleted to hide.
            Picker("Show", selection: $filter) {
                ForEach(MaskedEmailFilter.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which addresses to list")
        }

        ToolbarItem {
            Button {
                Task { await store.loadMaskedEmails() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(store.isLoadingMaskedEmails)
        }

        ToolbarSpacer(.flexible)

        ToolbarItem {
            Button {
                isCreating = true
            } label: {
                Label("New Masked Address", systemImage: "plus")
            }
            .help("New Masked Address (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!store.supportsMaskedEmail)
            .buttonStyle(.glassProminent)
        }
    }

    private func create(forDomain: String, note: String, prefix: String) async {
        guard let created = await store.createMaskedEmail(forDomain: forDomain, note: note, prefix: prefix) else {
            return
        }

        // The address is useless in the window and needed in the form you were
        // filling in, so creating one puts it straight on the clipboard.
        copy(created)
    }

    private func copy(_ masked: MaskedEmail) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(masked.email, forType: .string)
        copiedID = masked.id
    }
}

/// Which addresses the list shows.
private enum MaskedEmailFilter: CaseIterable, Hashable {
    /// Everything that still exists — the default, since a deleted address is
    /// gone as far as anyone signing up for something is concerned.
    case current
    case active
    case blocked
    case deleted

    var label: String {
        switch self {
        case .current: return "Current"
        case .active: return "Active"
        case .blocked: return "Blocked"
        case .deleted: return "Deleted"
        }
    }

    func includes(_ masked: MaskedEmail) -> Bool {
        switch self {
        case .current: return masked.state != .deleted
        case .active: return masked.state.isReceiving
        case .blocked: return masked.state == .disabled
        case .deleted: return masked.state == .deleted
        }
    }
}

private struct MaskedEmailRow: View {
    let masked: MaskedEmail
    let justCopied: Bool
    let onCopy: () -> Void
    let onSetState: (MaskedEmailState) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                // Selectable so the address can still be dragged or copied by
                // hand, monospaced because it will be compared character by
                // character with what a signup form shows back.
                Text(masked.email)
                    .font(.body.monospaced())
                    .textSelection(.enabled)

                HStack(spacing: Theme.Spacing.sm) {
                    if masked.displayName != masked.email {
                        Text(masked.displayName)
                            .lineLimit(1)
                    }

                    Text(activityDescription)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.sm)

            StateBadge(state: masked.state)

            Button {
                onCopy()
            } label: {
                Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy address")
            .symbolEffect(.bounce, value: justCopied)

            Menu {
                if masked.state != .enabled {
                    Button("Activate") { onSetState(.enabled) }
                }

                if masked.state != .disabled {
                    Button("Block") { onSetState(.disabled) }
                }

                if masked.state == .deleted {
                    Button("Restore") { onSetState(.enabled) }
                } else {
                    // A state, not a destroy: Fastmail keeps deleted addresses
                    // and bounces their mail, so this is undoable from the
                    // same menu.
                    Button("Delete", role: .destructive) { onSetState(.deleted) }
                }

                if let url = masked.url.flatMap(URL.init(string:)) {
                    Divider()
                    Link("Open \(url.host() ?? "Site")", destination: url)
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contextMenu {
            Button("Copy Address", action: onCopy)
        }
    }

    private var activityDescription: String {
        if let lastMessageAt = masked.lastMessageAt {
            return "last used \(lastMessageAt.formatted(.relative(presentation: .named)))"
        }

        if let createdAt = masked.createdAt {
            return "created \(createdAt.formatted(.relative(presentation: .named))), never used"
        }

        return "never used"
    }
}

private struct StateBadge: View {
    let state: MaskedEmailState

    var body: some View {
        Text(state.label)
            .font(.caption)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch state {
        case .enabled: return .green
        case .pending: return .orange
        case .disabled: return .secondary
        case .deleted: return .red
        case .unknown: return .secondary
        }
    }
}

/// Everything about a new address is optional — the point is one click and a
/// clipboard — so this exists only for the times you want to label it.
private struct NewMaskedEmailSheet: View {
    let onCreate: (String, String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var forDomain = ""
    @State private var note = ""
    @State private var prefix = ""
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("New Masked Address")
                .font(.headline)

            Form {
                TextField("Site", text: $forDomain, prompt: Text("example.com"))
                TextField("Note", text: $note, prompt: Text("What it's for"))
                TextField("Prefix", text: $prefix, prompt: Text("Optional, e.g. shop"))
            }
            .formStyle(.grouped)

            Text("The address is created immediately and copied to your clipboard. Leave the prefix empty and Fastmail picks the words itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Create") {
                    isCreating = true

                    Task {
                        await onCreate(forDomain, note, prefix)
                        isCreating = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
    }
}

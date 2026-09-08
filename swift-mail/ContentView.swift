//
//  ContentView.swift
//  swift-mail
//
//  Created by Declan Wade on 3/6/2026.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Group {
            if store.hasConfiguredAccount {
                MailHomeView(store: store)
            } else {
                AccountSetupView(store: store)
            }
        }
        .task {
            if store.hasConfiguredAccount && store.mailboxes.isEmpty {
                await store.refresh()
            }
        }
    }
}

private struct MailHomeView: View {
    @ObservedObject var store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            MailboxSidebarView(store: store)
        } content: {
            EmailListView(store: store)
        } detail: {
            EmailDetailView(store: store)
        }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if let message = store.backgroundErrorMessage {
                BackgroundErrorBanner(message: message) {
                    store.backgroundErrorMessage = nil
                }
            }
        }
        .alert("Mail Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // macOS 26 toolbar items are glass by default, and adjacent items merge
    // into one shared capsule — that merging is what gives Mail's toolbar its
    // segmented look. The previous toolbar forced `.buttonStyle(.glass)` on
    // every button, which opts each one *out* of merging and is exactly what
    // produced a row of disconnected pills instead. `ToolbarSpacer` is the
    // supported way to separate groups, so no button here carries an
    // explicit style. Items also no longer disappear when nothing is
    // selected — they disable instead — so the toolbar doesn't reflow every
    // time selection changes.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if let email = store.selectedEmail {
                    Task { await store.toggleReadState(emailID: email.id) }
                }
            } label: {
                Label(
                    store.selectedEmail?.isUnread == false ? "Mark as Unread" : "Mark as Read",
                    systemImage: store.selectedEmail?.isUnread == false ? "envelope.badge" : "envelope.open"
                )
            }
            .help(store.selectedEmail?.isUnread == false ? "Mark as Unread" : "Mark as Read")
            .disabled(store.selectedEmail == nil || store.updatingReadStateEmailIDs.contains(store.selectedEmail?.id ?? ""))

            Button {
                if let email = store.selectedEmail {
                    Task { await store.toggleFlag(emailID: email.id) }
                }
            } label: {
                Label("Flag", systemImage: store.selectedEmail?.isFlagged == true ? "flag.fill" : "flag")
                    .symbolEffect(.bounce, value: store.selectedEmail?.isFlagged)
            }
            .help("Flag")
            .tint(.orange)
            .disabled(store.selectedEmail == nil || store.updatingFlagEmailIDs.contains(store.selectedEmail?.id ?? ""))
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button {
                if let email = store.selectedEmail {
                    Task { await store.archive(emailID: email.id) }
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .symbolEffect(.bounce, value: store.movingEmailIDs.count)
            }
            .help("Archive (⌃⌘A)")
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(store.selectedEmail == nil || store.movingEmailIDs.contains(store.selectedEmail?.id ?? ""))

            Button(role: .destructive) {
                if let email = store.selectedEmail {
                    Task { await store.delete(emailID: email.id) }
                }
            } label: {
                Label("Delete", systemImage: "trash")
                    .symbolEffect(.bounce, value: store.movingEmailIDs.count)
            }
            .help("Delete (⌘⌫)")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(store.selectedEmail == nil || store.movingEmailIDs.contains(store.selectedEmail?.id ?? ""))
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button {
                if let email = store.selectedEmail {
                    compose(.reply(to: email, identity: store.defaultIdentity, replyAll: false))
                }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .help("Reply (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.selectedEmail == nil)

            Button {
                if let email = store.selectedEmail {
                    compose(.reply(to: email, identity: store.defaultIdentity, replyAll: true))
                }
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .help("Reply All (⇧⌘R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.selectedEmail == nil)

            Button {
                if let email = store.selectedEmail {
                    compose(.forward(email, identity: store.defaultIdentity))
                }
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .help("Forward (⇧⌘F)")
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(store.selectedEmail == nil)
        }

        ToolbarSpacer(.flexible)

        ToolbarItemGroup {
            Button {
                compose(.blank(identity: store.defaultIdentity))
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .help("New Message (⌘N)")

            Button {
                Task {
                    await store.refresh()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⇧⌘N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.isLoadingMailboxes || store.isLoadingEmails)
        }

        ToolbarItem {
            Menu {
                Button("Remove Account", role: .destructive) {
                    store.removeAccount()
                }
            } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
            .help("Account")
        }
    }

    private func compose(_ draft: ComposeDraft) {
        openWindow(id: ComposeWindow.id, value: draft)
    }
}

/// A non-modal banner for auto-fetch failures — a stale-data problem the user
/// didn't ask for shouldn't seize a modal alert the way a failed send does.
private struct BackgroundErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .lineLimit(2)

            Spacer(minLength: Theme.Spacing.sm)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(store: MailStore())
    }
}

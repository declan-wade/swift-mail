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
        .toolbar {
            ToolbarItemGroup {
                if let email = store.selectedEmail {
                    Button {
                        Task {
                            await store.toggleReadState(emailID: email.id)
                        }
                    } label: {
                        Label(email.isUnread ? "Mark as Read" : "Mark as Unread", systemImage: email.isUnread ? "envelope.open" : "envelope.badge")
                    }
                    .help(email.isUnread ? "Mark as Read" : "Mark as Unread")
                    .buttonStyle(.glass)
                    .disabled(store.updatingReadStateEmailIDs.contains(email.id))

                    Button {
                        // Hook flag handling here as JMAP mutation support lands.
                    } label: {
                        Label("Flag", systemImage: "flag")
                    }
                    .help("Flag")
                    .buttonStyle(.glass)

                    Button {
                        // Hook archive handling here as JMAP mutation support lands.
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .help("Archive")
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        // Hook delete handling here as JMAP mutation support lands.
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete")
                    .buttonStyle(.glass)

                    Button {
                        compose(.reply(to: email, identity: store.defaultIdentity, replyAll: false))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                    .buttonStyle(.glass)

                    Button {
                        compose(.reply(to: email, identity: store.defaultIdentity, replyAll: true))
                    } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    .help("Reply All (⇧⌘R)")
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .buttonStyle(.glass)

                    Button {
                        compose(.forward(email, identity: store.defaultIdentity))
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    .help("Forward (⇧⌘F)")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .buttonStyle(.glass)
                }

                Button {
                    compose(.blank(identity: store.defaultIdentity))
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message (⌘N)")
                .buttonStyle(.glass)

                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoadingMailboxes || store.isLoadingEmails)
                .buttonStyle(.glass)

                Menu {
                    Button("Remove Account", role: .destructive) {
                        store.removeAccount()
                    }
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .buttonStyle(.glass)
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

    private func compose(_ draft: ComposeDraft) {
        openWindow(id: ComposeWindow.id, value: draft)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(store: MailStore())
    }
}

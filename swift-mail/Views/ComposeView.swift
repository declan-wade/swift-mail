import AppKit
import SwiftUI

enum ComposeWindow {
    static let id = "compose"
}

/// Which surface a previewing compose window shows.
enum PreviewMode: String {
    /// Native SwiftUI rendering of the same source — see `MarkdownPreview`.
    case native
    /// The actual outgoing HTML, rendered in a `WKWebView` on its own opaque
    /// page so it reads the same regardless of the app's own appearance.
    case recipient
}

/// A single compose window.
///
/// The draft is window-local `@State` seeded from the value the window was opened
/// with, so several replies can be open at once without sharing state through the
/// store. The store is only touched to send or to save.
struct ComposeView: View {
    @ObservedObject var store: MailStore
    @State private var draft: ComposeDraft
    @State private var isPreviewing = false
    @AppStorage("swift-mail.compose.previewMode") private var previewMode = PreviewMode.native
    @State private var isSending = false
    @State private var isSaving = false
    @State private var isConfirmingEmptySubject = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(store: MailStore, draft: ComposeDraft) {
        self.store = store
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            ComposeHeader(draft: $draft, identities: store.identities)

            Divider()

            Group {
                if isPreviewing {
                    switch previewMode {
                    case .native:
                        MarkdownPreview(markdown: draft.markdown)
                    case .recipient:
                        HTMLMessageView(
                            html: MarkdownRenderer.htmlDocument(from: draft.markdown, palette: .wire),
                            chrome: .opaque
                        )
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                        .padding(Theme.Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    }
                } else {
                    MarkdownEditor(text: $draft.markdown)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ComposeStatusBar(markdown: draft.markdown, status: statusMessage, isPreviewing: isPreviewing, previewMode: $previewMode)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 560, minHeight: 440)
        .navigationTitle(draft.windowTitle)
        .toolbar { toolbar }
        .task {
            if store.identities.isEmpty {
                await store.loadIdentities()
            }

            if draft.identityID == nil {
                draft.identityID = store.defaultIdentity?.id
            }
        }
        .confirmationDialog(
            "Send without a subject?",
            isPresented: $isConfirmingEmptySubject
        ) {
            Button("Send") {
                Task { await performSend() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Compose Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // macOS 26 toolbar items are glass by default and merge into one shared
    // capsule when adjacent — that's what gives Mail's toolbar its segmented
    // look. Forcing `.buttonStyle(.glass)` on each button (the previous code
    // here) opts every one of them *out* of that merging, which is what
    // produced a row of disconnected pills instead. `ToolbarSpacer` is the
    // supported way to separate groups; only Send keeps an explicit style,
    // since `.glassProminent` is a deliberate visual departure, not a fix.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                isPreviewing.toggle()
            } label: {
                Label(isPreviewing ? "Edit" : "Preview", systemImage: isPreviewing ? "pencil" : "eye")
            }
            .help(isPreviewing ? "Back to Markdown (⇧⌘P)" : "Preview rendered message (⇧⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }

        ToolbarSpacer(.flexible)

        ToolbarItem {
            Button {
                Task { await performSaveDraft() }
            } label: {
                Label("Save Draft", systemImage: "tray.and.arrow.down")
            }
            .help("Save Draft (⌘S)")
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSending || isSaving)
        }

        ToolbarItem {
            Button {
                requestSend()
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .help("Send (⌘↩)")
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .buttonStyle(.glassProminent)
        }
    }

    private var canSend: Bool {
        draft.hasRecipients && !isSending && !isSaving
    }

    private func requestSend() {
        commitPendingEdits()

        guard draft.hasRecipients else {
            errorMessage = "Add at least one recipient before sending."
            return
        }

        guard !draft.subject.trimmingCharacters(in: .whitespaces).isEmpty else {
            isConfirmingEmptySubject = true
            return
        }

        Task { await performSend() }
    }

    private func performSend() async {
        isSending = true
        statusMessage = "Sending…"
        defer { isSending = false }

        do {
            try await store.send(draft)
            dismiss()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func performSaveDraft() async {
        commitPendingEdits()

        isSaving = true
        statusMessage = "Saving…"
        defer { isSaving = false }

        do {
            try await store.saveDraft(draft)
            statusMessage = "Saved to Drafts"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    /// A recipient typed without a trailing comma is still in the token field's
    /// editor, so end editing before reading the draft.
    private func commitPendingEdits() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

// MARK: - Header

private struct ComposeHeader: View {
    @Binding var draft: ComposeDraft
    let identities: [MailIdentity]

    var body: some View {
        VStack(spacing: 0) {
            if identities.count > 1 {
                ComposeFieldRow(label: "From") {
                    Picker("From", selection: identitySelection) {
                        ForEach(identities) { identity in
                            Text(identity.displayName).tag(identity.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            ComposeFieldRow(label: "To") {
                HStack(spacing: Theme.Spacing.sm) {
                    RecipientField(addresses: $draft.to, placeholder: "")

                    Button {
                        draft.showsCarbonCopy.toggle()
                    } label: {
                        Image(systemName: draft.showsCarbonCopy ? "minus.circle" : "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(draft.showsCarbonCopy ? "Hide Cc and Bcc" : "Show Cc and Bcc")
                }
            }

            if draft.showsCarbonCopy {
                ComposeFieldRow(label: "Cc") {
                    RecipientField(addresses: $draft.cc, placeholder: "")
                }

                ComposeFieldRow(label: "Bcc") {
                    RecipientField(addresses: $draft.bcc, placeholder: "")
                }
            }

            ComposeFieldRow(label: "Subject", showsDivider: false) {
                TextField("Subject", text: $draft.subject)
                    .textFieldStyle(.plain)
            }
        }
        .background(.bar)
    }

    /// The picker needs a non-optional selection; the draft stores it optionally
    /// because a draft can outlive the identity list being loaded.
    private var identitySelection: Binding<String> {
        Binding(
            get: { draft.identityID ?? identities.first?.id ?? "" },
            set: { draft.identityID = $0 }
        )
    }
}

private struct ComposeFieldRow<Content: View>: View {
    let label: String
    var showsDivider = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md - 2) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.Size.fieldLabel, alignment: .trailing)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm - 1)

            if showsDivider {
                Divider()
                    .padding(.leading, Theme.Spacing.lg)
            }
        }
    }
}

// MARK: - Status bar

private struct ComposeStatusBar: View {
    let markdown: String
    let status: String?
    let isPreviewing: Bool
    @Binding var previewMode: PreviewMode

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isPreviewing {
                Picker("Preview", selection: $previewMode) {
                    Text("Preview").tag(PreviewMode.native)
                    Text("As Recipient Sees It").tag(PreviewMode.recipient)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Label("Markdown", systemImage: "textformat")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)

                Text(shortcutHint)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if let status {
                Text(status)
                    .foregroundStyle(.secondary)
            }

            Text("\(wordCount) words")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm - 2)
        .background(.bar)
    }

    private var shortcutHint: String {
        "⌘B bold · ⌘I italic · ⌘K link · ⇧⌘C code"
    }

    private var wordCount: Int {
        markdown.split(whereSeparator: \.isWhitespace).count
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ComposeWindow {
    static let id = "compose"
}

/// How a compose window divides its space. Persisted, so a preference for
/// working side by side survives closing the window.
enum ComposeLayout: String {
    case editor
    case split
    case preview

    var showsEditor: Bool { self != .preview }
    var showsPreview: Bool { self != .editor }
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
    @AppStorage("swift-mail.compose.layout") private var layout = ComposeLayout.editor
    @AppStorage("swift-mail.compose.previewMode") private var previewMode = PreviewMode.native
    /// Trails `draft.markdown`. The recipient preview reloads a `WKWebView`,
    /// which is far too heavy to redo on every keystroke while typing next to
    /// it in split view.
    @State private var debouncedMarkdown: String
    /// The draft as last opened, sent or saved. Closing compares against this
    /// so only genuine unsaved edits raise the prompt.
    @State private var savedDraft: ComposeDraft
    @State private var isSending = false
    @State private var isSaving = false
    @State private var isConfirmingEmptySubject = false
    @State private var errorMessage: String?
    @State private var isChoosingAttachments = false
    @State private var isAttaching = false
    @State private var isDropTargeted = false
    @State private var statusMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(store: MailStore, draft: ComposeDraft) {
        self.store = store
        _draft = State(initialValue: draft)
        _debouncedMarkdown = State(initialValue: draft.markdown)
        _savedDraft = State(initialValue: draft)
    }

    private var hasUnsavedChanges: Bool {
        draft.hasChanges(from: savedDraft)
    }

    var body: some View {
        VStack(spacing: 0) {
            ComposeHeader(draft: $draft, identities: store.identities)

            Divider()

            if !draft.attachments.isEmpty || isAttaching {
                AttachmentStrip(
                    attachments: draft.attachments,
                    isAttaching: isAttaching,
                    onRemove: { attachment in
                        draft.attachments.removeAll { $0.id == attachment.id }
                    }
                )

                Divider()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // `URL` is what Finder and Mail put on the pasteboard, and
                // SwiftUI's own drop handling saves reimplementing NSDraggingInfo.
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await attach(urls) }
                    return true
                } isTargeted: { isDropTargeted = $0 }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(Theme.Spacing.sm)
                            .allowsHitTesting(false)
                    }
                }

            Divider()

            ComposeStatusBar(markdown: draft.markdown, status: statusMessage, layout: layout, previewMode: $previewMode)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Two panes need room to be worth having; the window grows to meet it.
        .frame(minWidth: layout == .split ? 900 : 560, minHeight: 440)
        .background {
            // ⇧⌘P keeps its old meaning: flip between writing and previewing,
            // returning to the editor from either layout that shows a preview.
            // It has no toolbar item of its own — the layout picker is the
            // visible control — and a hidden `ToolbarItem` would still reserve
            // its slot and draw an empty capsule, so it lives here instead.
            Button("Toggle Preview") {
                layout = layout == .editor ? .preview : .editor
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .hidden()
        }
        .fileImporter(
            isPresented: $isChoosingAttachments,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await attach(urls) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .task(id: draft.markdown) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else {
                return
            }

            debouncedMarkdown = draft.markdown
        }
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
        // Native window-close interception (macOS 15+), so ⌘W, the red button
        // and Quit all route through the same prompt without an
        // `NSWindowDelegate` bridge.
        .dismissalConfirmationDialog(
            "Save this message as a draft?",
            shouldPresent: hasUnsavedChanges
        ) {
            Button("Save Draft") {
                // Unstructured on purpose: this outlives the window being torn
                // down, and a failure is reported through the store so it still
                // surfaces once this window is gone.
                Task { await saveOnClose() }
            }

            Button("Discard", role: .destructive) {}

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closing without saving will discard your changes.")
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

    /// Uploads dropped or chosen files, skipping directories and reporting the
    /// first failure rather than silently attaching a partial set.
    private func attach(_ urls: [URL]) async {
        guard !urls.isEmpty else {
            return
        }

        isAttaching = true
        defer { isAttaching = false }

        for url in urls {
            do {
                guard let file = try Self.readFile(at: url) else {
                    continue
                }

                let attachment = try await store.uploadAttachment(
                    data: file.data,
                    name: url.lastPathComponent,
                    type: file.type
                )

                // A file dropped twice is one attachment, not two.
                if !draft.attachments.contains(where: { $0.blobId == attachment.blobId }) {
                    draft.attachments.append(attachment)
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    /// Reads a user-selected file. Sandboxed builds only reach outside the
    /// container through a security-scoped URL, which has to be opened and
    /// closed around the read.
    private static func readFile(at url: URL) throws -> (data: Data, type: String)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory != true else {
            return nil
        }

        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        return (try Data(contentsOf: url), type)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .editor:
            editor
        case .preview:
            preview
        case .split:
            // `HSplitView` is the AppKit-backed splitter, so the divider is
            // draggable and its position persists the way the rest of macOS
            // behaves — nothing to hand-roll.
            HSplitView {
                editor.frame(minWidth: 320)
                preview.frame(minWidth: 320)
            }
        }
    }

    private var editor: some View {
        MarkdownEditor(text: $draft.markdown)
    }

    @ViewBuilder
    private var preview: some View {
        switch previewMode {
        case .native:
            // Cheap enough to re-render per keystroke, so this one stays live.
            MarkdownPreview(markdown: draft.markdown)
        case .recipient:
            HTMLMessageView(
                html: MarkdownRenderer.htmlDocument(from: debouncedMarkdown, palette: .wire),
                chrome: .opaque
            )
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
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
            Picker("Layout", selection: $layout) {
                Label("Editor", systemImage: "pencil").tag(ComposeLayout.editor)
                Label("Split", systemImage: "rectangle.split.2x1").tag(ComposeLayout.split)
                Label("Preview", systemImage: "eye").tag(ComposeLayout.preview)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Editor, side by side, or preview")
        }


        ToolbarItem {
            Button {
                isChoosingAttachments = true
            } label: {
                Label("Attach Files", systemImage: "paperclip")
            }
            .help("Attach Files (⇧⌘A)")
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(isAttaching)
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
            // The message is gone; there is nothing left unsaved, and without
            // this the close below would raise the save-draft prompt on a
            // message that has just been sent.
            savedDraft = draft
            dismiss()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Saving as the window closes. The compose window's own error alert dies
    /// with it, so a failure here has to be reported somewhere that outlives
    /// it — otherwise the draft vanishes silently, which is the one outcome
    /// this prompt exists to prevent.
    private func saveOnClose() async {
        commitPendingEdits()

        do {
            try await store.saveDraft(draft)
        } catch {
            store.errorMessage = "The draft could not be saved: \(error.localizedDescription)"
        }
    }

    private func performSaveDraft() async {
        commitPendingEdits()

        isSaving = true
        statusMessage = "Saving…"
        defer { isSaving = false }

        do {
            try await store.saveDraft(draft)
            savedDraft = draft
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

/// The attached files, listed above the editor the way Mail shows them.
private struct AttachmentStrip: View {
    let attachments: [ComposeAttachment]
    let isAttaching: Bool
    let onRemove: (ComposeAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: icon(for: attachment))
                            .foregroundStyle(.secondary)

                        Text(attachment.name)
                            .lineLimit(1)

                        Text(attachment.sizeDescription)
                            .foregroundStyle(.secondary)

                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Remove \(attachment.name)")
                    }
                    .font(.callout)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.quaternary, in: Capsule())
                }

                if isAttaching {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, Theme.Spacing.xs)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .scrollIndicators(.never)
    }

    private func icon(for attachment: ComposeAttachment) -> String {
        UTType(mimeType: attachment.type).map { type in
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .archive) { return "doc.zipper" }
            if type.conforms(to: .movie) { return "film" }
            if type.conforms(to: .audio) { return "waveform" }
            return "doc"
        } ?? "doc"
    }
}

private struct ComposeStatusBar: View {
    let markdown: String
    let status: String?
    let layout: ComposeLayout
    @Binding var previewMode: PreviewMode

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Split shows both: the preview needs its mode picker and the
            // editor still needs its shortcuts.
            if layout.showsPreview {
                Picker("Preview", selection: $previewMode) {
                    Text("Preview").tag(PreviewMode.native)
                    Text("As Recipient Sees It").tag(PreviewMode.recipient)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if layout.showsEditor {
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
        "⌘1–3 headings · ⇧⌘L list · ⇧⌘O numbered · ⌘' quote · ⌘B bold · ⌘I italic · ⌘K link · ⇧⌘C code"
    }

    private var wordCount: Int {
        markdown.split(whereSeparator: \.isWhitespace).count
    }
}

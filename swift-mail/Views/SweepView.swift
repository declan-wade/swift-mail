import SwiftUI

/// Bulk-moves everything matching a query into one mailbox, after showing what
/// it would touch. Every destination — Archive, Trash, Spam, a folder — is the
/// same move, so the sheet only ever asks for a query and a target.
struct SweepView: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var destinationID: String?
    @State private var preview: MailStore.SweepPreview?
    @State private var isPreviewing = false
    @State private var isSweeping = false
    @State private var errorMessage: String?
    @State private var previewTask: Task<Void, Never>?

    private var matchCount: Int? {
        preview.map { $0.total ?? $0.previews.count }
    }

    private var canSweep: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && (matchCount ?? 0) > 0
            && destinationID != nil
            && !isSweeping
    }

    var body: some View {
        // spacing 0 with padding on each block, and a results area that takes
        // every spare point: that's what pins the header to the top and the
        // buttons to the bottom instead of floating the whole stack mid-sheet.
        VStack(spacing: 0) {
            header
            Divider()

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 580, height: 600)
        .onAppear {
            destinationID = store.mailbox(role: "archive")?.id
        }
        .onDisappear { previewTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Sweep \(store.selectedMailbox?.displayName ?? "Mailbox")")
                    .font(.headline)

                // A sweep inherits whichever tag the window is narrowed to,
                // and a bulk move is the last place to leave that implicit.
                if let tag = store.activeTag {
                    Text("\(tag.displayName) only")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tag.color.color)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(tag.color.color.opacity(0.18), in: Capsule())
                }
            }

            // The prompt stays instructional. An example here reads as a value
            // already typed in, which is exactly the wrong impression on a
            // sheet whose button moves mail.
            TextField("Search\u{2026}", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onChange(of: query) { _, _ in schedulePreview() }

            Text("Same syntax as search — try \u{201C}from:newsletter is:read before:30d\u{201D}. Add in:all to sweep every mailbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var results: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Preview", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty query would mean "the entire folder", which is never
            // what a sweep should silently agree to.
            ContentUnavailableView(
                "Nothing to Sweep Yet",
                systemImage: "magnifyingglass",
                description: Text("Describe the messages to sweep and they'll be listed here first.")
            )
        } else if isPreviewing && preview == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview, preview.previews.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "tray",
                description: Text("Nothing in this mailbox matches that search.")
            )
        } else if let preview {
            VStack(spacing: 0) {
                summaryBar
                Divider()

                List(preview.previews) { email in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(email.senderLine)
                                .fontWeight(.medium)
                                .lineLimit(1)

                            Spacer(minLength: Theme.Spacing.sm)

                            if let receivedAt = email.receivedAt {
                                Text(DateFormatter.mailShort.string(from: receivedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(email.subjectLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        } else {
            Color.clear
        }
    }

    private var summaryBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(countSummary)
                .font(.callout.weight(.medium))

            if isPreviewing {
                ProgressView().controlSize(.small)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    /// Says plainly when the list shown is only the first page of the match.
    private var countSummary: String {
        guard let preview, let count = matchCount else {
            return ""
        }

        let noun = count == 1 ? "message" : "messages"

        return preview.previews.count < count
            ? "\(count.formatted()) \(noun) match — showing the first \(preview.previews.count)"
            : "\(count.formatted()) \(noun) match"
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            Picker("Move to", selection: $destinationID) {
                ForEach(destinations, id: \.id) { mailbox in
                    Label(mailbox.displayName, systemImage: mailbox.iconName).tag(mailbox.id as String?)
                }
            }
            .frame(maxWidth: 240)

            Spacer(minLength: Theme.Spacing.sm)

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                Task { await sweep() }
            } label: {
                Text(sweepLabel).lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSweep)
        }
        .padding(Theme.Spacing.lg)
    }

    /// Names the destination as well as the count: this button moves mail, and
    /// the picker beside it is easy to skim past.
    private var sweepLabel: String {
        guard let count = matchCount, count > 0 else {
            return "Sweep"
        }

        if isSweeping {
            return "Sweeping\u{2026}"
        }

        let destination = store.mailboxes.first { $0.id == destinationID }?.displayName

        return destination.map { "Sweep \(count.formatted()) to \($0)" } ?? "Sweep \(count.formatted())"
    }

    /// System mailboxes first, then the user's folders — the same split the
    /// sidebar uses.
    private var destinations: [Mailbox] {
        store.mailboxes.filter(\.isSystem) + store.mailboxes.filter { !$0.isSystem }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        errorMessage = nil

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            preview = nil
            isPreviewing = false
            return
        }

        isPreviewing = true
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            do {
                let result = try await store.previewSweep(query: query)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                preview = nil
            }

            isPreviewing = false
        }
    }

    private func sweep() async {
        guard let destinationID else { return }

        isSweeping = true
        errorMessage = nil

        do {
            _ = try await store.performSweep(query: query, toMailboxID: destinationID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSweeping = false
    }
}

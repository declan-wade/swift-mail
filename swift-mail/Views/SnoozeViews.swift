import SwiftUI

/// The Snooze menu's contents: the presets from Settings, a time of your own,
/// and the way back out for a message that is already snoozed. One view for
/// the toolbar, the message list and the sidebar, so the three can't drift.
struct SnoozeMenuItems: View {
    @ObservedObject var store: MailStore
    let emailID: EmailPreview.ID
    @AppStorage(SnoozePreferences.presetsKey) private var presetData: Data?

    var body: some View {
        let presets = SnoozePreferences.presets(from: presetData).filter { $0.date(from: .now) != nil }

        // Filtered when the menu is built but resolved when clicked: a toolbar
        // menu's contents can be hours old, and "In 3 Hours" means from now.
        ForEach(presets) { preset in
            Button(preset.label()) {
                guard let date = preset.date(from: .now) else {
                    return
                }

                Task { await store.snooze(emailID: emailID, until: date) }
            }
        }

        if !presets.isEmpty {
            Divider()
        }

        Button("Custom\u{2026}") {
            store.customSnoozeEmailID = emailID
        }

        if store.snoozedEmails.contains(where: { $0.id == emailID }) {
            Divider()

            Button("Unsnooze") {
                Task { await store.unsnooze(emailID: emailID) }
            }
        }
    }
}

/// A time of your own, for when none of the presets fits.
struct CustomSnoozeSheet: View {
    let onSnooze: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The top of the next hour: a default to the minute would only ever need
    /// correcting.
    @State private var date = Calendar.current.nextDate(
        after: .now,
        matching: DateComponents(minute: 0, second: 0),
        matchingPolicy: .nextTime
    ) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Snooze Until")
                .font(.headline)

            DatePicker("Snooze until", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Snooze") {
                    onSnooze(date)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(date <= .now)
            }
        }
        .padding(Theme.Spacing.lg)
        .fixedSize()
    }
}

/// What is coming back and when, soonest first, pinned under the folders so
/// it can be checked without opening the Snoozed mailbox.
struct SnoozedSidebarList: View {
    @ObservedObject var store: MailStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Snoozed", systemImage: "moon.zzz")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xs)

            // Only as tall as its rows, up to a few of them, then it scrolls:
            // a glance mustn't push the folders out of the sidebar.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
            .frame(maxHeight: 160)
            .padding(.bottom, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.snoozedEmails) { email in
                row(for: email)
            }
        }
    }

    private func row(for email: SnoozedEmail) -> some View {
        Button {
            store.openSnoozed(emailID: email.id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(email.subjectLine)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.xs) {
                    Text(email.senderLine)
                        .lineLimit(1)

                    Spacer(minLength: Theme.Spacing.xs)

                    if let until = email.snoozed?.until {
                        Text(Self.wakeDescription(until))
                            .monospacedDigit()
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(email.snoozed.map { "Back \($0.until.formatted(date: .complete, time: .shortened))" } ?? "")
        .contextMenu {
            SnoozeMenuItems(store: store, emailID: email.id)
        }
    }

    /// A weekday and time inside the coming week; past that a weekday stops
    /// being unambiguous, so a date.
    private static func wakeDescription(_ until: Date, now: Date = Date()) -> String {
        until.timeIntervalSince(now) < 6 * 86_400
            ? until.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : until.formatted(.dateTime.day().month(.abbreviated))
    }
}

import Foundation

/// One time the Snooze menu offers.
///
/// Flat rather than an enum with associated values so Settings can bind a
/// picker straight to each field. Every kind but `hoursLater` resolves against
/// a real calendar, so "tomorrow at 8" stays 8am across a daylight-saving
/// change.
nonisolated struct SnoozePreset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case hoursLater
        case today
        case tomorrow
        case weekday

        var id: String { rawValue }

        /// Reads as the start of the row it heads in Settings: "Next ·
        /// Saturday · 9:00 AM", "In · 3 hours".
        var settingsLabel: String {
            switch self {
            case .hoursLater: "In"
            case .today: "Today at"
            case .tomorrow: "Tomorrow at"
            case .weekday: "Next"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Hours to wait for `hoursLater`; the hour of the day (0–23) otherwise.
    var hour: Int
    /// 1 (Sunday) through 7, as `Calendar` counts them. Only read for `weekday`.
    var weekday = 2

    /// `nil` when the moment has already gone — "today at 6pm" offered at 9pm.
    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .hoursLater:
            // At least an hour: zero would snooze a message until it woke again.
            return calendar.date(byAdding: .hour, value: max(1, hour), to: now)
        case .today:
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now).flatMap { $0 > now ? $0 : nil }
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: now)
                .flatMap { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }
        case .weekday:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday),
                matchingPolicy: .nextTime
            )
        }
    }

    func label(calendar: Calendar = .current) -> String {
        switch kind {
        case .hoursLater:
            max(1, hour) == 1 ? "In 1 Hour" : "In \(hour) Hours"
        case .today:
            "Today at \(Self.hourText(hour, calendar: calendar))"
        case .tomorrow:
            "Tomorrow at \(Self.hourText(hour, calendar: calendar))"
        case .weekday:
            "\(calendar.weekdaySymbols[min(max(weekday, 1), 7) - 1]) at \(Self.hourText(hour, calendar: calendar))"
        }
    }

    /// "6:00 PM" or "18:00", whichever this Mac's locale writes.
    static func hourText(_ hour: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

nonisolated enum SnoozePreferences {
    /// JSON-encoded `[SnoozePreset]`. Unset means the defaults.
    static let presetsKey = "swift-mail.snooze.presets"
    static let showsSidebarListKey = "swift-mail.sidebar.showsSnoozed"

    /// A `let`, so the ids stay put for as long as the app runs and the menu
    /// isn't rebuilt from scratch every time it is read.
    static let defaultPresets = [
        SnoozePreset(kind: .hoursLater, hour: 3),
        SnoozePreset(kind: .today, hour: 18),
        SnoozePreset(kind: .tomorrow, hour: 8),
        SnoozePreset(kind: .weekday, hour: 9, weekday: 7),
        SnoozePreset(kind: .weekday, hour: 8, weekday: 2)
    ]

    /// An empty list saved on purpose stays empty; only a missing or unreadable
    /// value falls back to the defaults.
    static func presets(from data: Data?) -> [SnoozePreset] {
        guard let data, let presets = try? JSONDecoder().decode([SnoozePreset].self, from: data) else {
            return defaultPresets
        }

        return presets
    }

    static func data(for presets: [SnoozePreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }
}

/// A message waiting in the Snoozed mailbox, as the sidebar lists it.
nonisolated struct SnoozedEmail: Identifiable, Hashable, Decodable {
    /// The draft's `SnoozeDetails`. Only the wake-up time is read; where it
    /// goes and what it sets are the server's business once it's filed.
    struct Details: Hashable, Decodable {
        let until: Date
    }

    let id: String
    let subject: String?
    let from: [EmailAddress]?
    let snoozed: Details?

    var subjectLine: String {
        subject?.nilIfEmpty ?? "No Subject"
    }

    var senderLine: String {
        from?.first?.name?.nilIfEmpty ?? from?.first?.email ?? "Unknown Sender"
    }

    static func soonestFirst(_ lhs: SnoozedEmail, _ rhs: SnoozedEmail) -> Bool {
        (lhs.snoozed?.until ?? .distantFuture) < (rhs.snoozed?.until ?? .distantFuture)
    }
}

//
//  SnoozePresetTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// A preset that resolves to the wrong moment snoozes mail until a time nobody
/// chose, and nothing on screen says so until it fails to come back.
struct SnoozePresetTests {
    /// Thursday 4 September 2025, 15:33:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(day: Int, hour: Int) -> Date? {
        calendar.date(from: DateComponents(year: 2025, month: 9, day: day, hour: hour))
    }

    @Test func hoursLaterCountsFromNow() {
        #expect(SnoozePreset(kind: .hoursLater, hour: 3).date(from: now, calendar: calendar) == now.addingTimeInterval(3 * 3600))
        #expect(SnoozePreset(kind: .hoursLater, hour: 0).date(from: now, calendar: calendar) == now.addingTimeInterval(3600))
    }

    @Test func todayIsOfferedOnlyUntilItPasses() {
        #expect(SnoozePreset(kind: .today, hour: 18).date(from: now, calendar: calendar) == date(day: 4, hour: 18))
        #expect(SnoozePreset(kind: .today, hour: 9).date(from: now, calendar: calendar) == nil)
    }

    @Test func tomorrowLandsOnTheHour() {
        #expect(SnoozePreset(kind: .tomorrow, hour: 8).date(from: now, calendar: calendar) == date(day: 5, hour: 8))
    }

    @Test func weekdayFindsTheNextOneAhead() {
        #expect(SnoozePreset(kind: .weekday, hour: 9, weekday: 7).date(from: now, calendar: calendar) == date(day: 6, hour: 9))
        // Thursday 9am has already gone today, so it means next Thursday.
        #expect(SnoozePreset(kind: .weekday, hour: 9, weekday: 5).date(from: now, calendar: calendar) == date(day: 11, hour: 9))
    }

    @Test func storageFallsBackToDefaultsOnlyWhenUnreadable() {
        #expect(SnoozePreferences.presets(from: nil) == SnoozePreferences.defaultPresets)
        #expect(SnoozePreferences.presets(from: Data("junk".utf8)) == SnoozePreferences.defaultPresets)
        #expect(SnoozePreferences.presets(from: SnoozePreferences.data(for: [])).isEmpty)

        let custom = [SnoozePreset(kind: .weekday, hour: 7, weekday: 1)]
        #expect(SnoozePreferences.presets(from: SnoozePreferences.data(for: custom)) == custom)
    }

    /// Snoozing and archiving both replace `mailboxIds`, so whichever the user
    /// did last is the one the outbox sends.
    @Test func snoozeSupersedesAQueuedMove() {
        let snooze = OutboxEntry(emailID: "e1", action: .snooze(mailboxID: "snoozed", until: now))
        let move = OutboxEntry(emailID: "e1", action: .move(mailboxID: "archive"))
        #expect(snooze.coalescingKey == move.coalescingKey)
    }
}

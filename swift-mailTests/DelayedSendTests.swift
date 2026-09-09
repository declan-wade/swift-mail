//
//  DelayedSendTests.swift
//  swift-mailTests
//

import Foundation
import Testing
@testable import swift_mail

/// Send later and undo send are one mechanism — a submission held by the server
/// until `sendAt` — so these cover the two things that can silently break it:
/// asking for a hold the server will reject, and reverting a message that was
/// never actually recalled.
struct DelayedSendTests {
    private let identity = MailIdentity(
        id: "identity-1",
        name: "Ana",
        email: "ana@example.com",
        replyTo: nil,
        bcc: nil,
        textSignature: nil,
        htmlSignature: nil
    )

    private var draft: ComposeDraft {
        var draft = ComposeDraft()
        draft.to = [EmailAddress(email: "bo@example.com")]
        draft.subject = "Hello"
        return draft
    }

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func session(json: String) throws -> JMAPSession {
        try JSONDecoder().decode(JMAPSession.self, from: Data(json.utf8))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    // MARK: - maxDelayedSend

    @Test("The account's own submission limit wins over the server's")
    func accountLimitWins() throws {
        let session = try session(json: """
        {
            "apiUrl": "https://api.example.com/jmap/",
            "primaryAccounts": {},
            "capabilities": {
                "urn:ietf:params:jmap:submission": { "maxDelayedSend": 86400 }
            },
            "accounts": {
                "u1": {
                    "accountCapabilities": {
                        "urn:ietf:params:jmap:submission": { "maxDelayedSend": 3600 }
                    }
                }
            }
        }
        """)

        #expect(session.maxDelayedSend(accountID: "u1") == 3600)
        // An account the session doesn't describe falls back to the server's.
        #expect(session.maxDelayedSend(accountID: "u2") == 86400)
    }

    @Test("A server that never mentions maxDelayedSend holds nothing")
    func absentLimitIsZero() throws {
        let session = try session(json: """
        {
            "apiUrl": "https://api.example.com/jmap/",
            "primaryAccounts": {},
            "capabilities": { "urn:ietf:params:jmap:submission": {} }
        }
        """)

        #expect(session.maxDelayedSend(accountID: "u1") == 0)
    }

    // MARK: - Choosing the release time

    @Test("With no delay configured, an ordinary send asks for no hold")
    func noDelayMeansImmediate() {
        let release = SendPreferences.releaseDate(
            requested: nil,
            undoDelay: 0,
            maxDelayedSend: 3600,
            now: now
        )

        #expect(release == nil)
    }

    @Test("The undo delay becomes the release time")
    func undoDelayHolds() {
        let release = SendPreferences.releaseDate(
            requested: nil,
            undoDelay: 10,
            maxDelayedSend: 3600,
            now: now
        )

        #expect(release == now.addingTimeInterval(10))
    }

    @Test("A server that holds nothing overrides the preference")
    func unsupportedServerSendsImmediately() {
        let release = SendPreferences.releaseDate(
            requested: now.addingTimeInterval(3600),
            undoDelay: 10,
            maxDelayedSend: 0,
            now: now
        )

        #expect(release == nil)
    }

    @Test("A request beyond the server's limit is clamped, not rejected")
    func requestIsClamped() {
        let release = SendPreferences.releaseDate(
            requested: now.addingTimeInterval(999_999),
            undoDelay: 0,
            maxDelayedSend: 3600,
            now: now
        )

        #expect(release == now.addingTimeInterval(3600))
    }

    @Test("A schedule that has already lapsed sends immediately")
    func pastRequestSendsNow() {
        let release = SendPreferences.releaseDate(
            requested: now.addingTimeInterval(-60),
            undoDelay: 10,
            maxDelayedSend: 3600,
            now: now
        )

        #expect(release == nil)
    }

    // MARK: - Presets

    @Test("Presets the server can't hold long enough are not offered")
    func presetsRespectTheLimit() throws {
        let calendar = utcCalendar
        // 9am on Wednesday 9 September 2026.
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 9)))

        // Two hours of hold reaches nothing: the evening is nine hours out.
        #expect(SendLaterPreset.available(from: morning, within: 7200, calendar: calendar).isEmpty)

        // A full day reaches this evening and tomorrow morning, but not Monday.
        let day = SendLaterPreset.available(from: morning, within: 86_400, calendar: calendar)
        #expect(day.map(\.preset) == [.thisEvening, .tomorrowMorning])
    }

    @Test("An evening that has already passed is not offered")
    func eveningLapses() throws {
        let calendar = utcCalendar
        let lateNight = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 23)))

        #expect(SendLaterPreset.thisEvening.date(from: lateNight, calendar: calendar) == nil)
    }

    // MARK: - Request shape

    @Test("sendAt is omitted entirely for an immediate send")
    func immediateSendOmitsSendAt() {
        let arguments = JMAPClient.submitArguments(
            accountID: "u1",
            draft: draft,
            identity: identity,
            draftsMailboxID: "drafts",
            fileInMailboxID: "sent",
            sendAt: nil
        )

        let create = arguments["create"] as? [String: Any]
        let submission = create?["submission"] as? [String: Any]

        #expect(submission?["sendAt"] == nil)
        #expect(submission?["emailId"] as? String == "#draft")
    }

    @Test("A held send carries sendAt as a seconds-precision UTC date")
    func heldSendCarriesSendAt() {
        let arguments = JMAPClient.submitArguments(
            accountID: "u1",
            draft: draft,
            identity: identity,
            draftsMailboxID: "drafts",
            fileInMailboxID: "sent",
            sendAt: now
        )

        let create = arguments["create"] as? [String: Any]
        let submission = create?["submission"] as? [String: Any]

        #expect(submission?["sendAt"] as? String == JMAPClient.utcDate(now))
        // Seconds precision, always Z — RFC 8620 §1.4.
        #expect(JMAPClient.utcDate(now) == "2025-09-04T15:33:20Z")
    }

    @Test("Send and cancel agree on the mailbox a held message is filed in")
    func heldSendRoundTripsThroughScheduled() throws {
        let submit = JMAPClient.submitArguments(
            accountID: "u1",
            draft: draft,
            identity: identity,
            draftsMailboxID: "drafts",
            fileInMailboxID: "scheduled",
            sendAt: now
        )

        let filed = try #require(
            (submit["onSuccessUpdateEmail"] as? [String: Any])?["#submission"] as? [String: Any]
        )

        // Into Scheduled, out of Drafts — it hasn't been sent yet.
        #expect(filed["mailboxIds/scheduled"] as? Bool == true)
        #expect(filed["mailboxIds/drafts"] is NSNull)

        let cancel = JMAPClient.cancelArguments(
            accountID: "u1",
            submissionID: "sub-1",
            draftsMailboxID: "drafts",
            fileInMailboxID: "scheduled"
        )

        // And exactly back out again: a cancel that named Sent here would leave
        // the recalled message sitting in Scheduled forever.
        let revert = try #require(
            (cancel["onSuccessUpdateEmail"] as? [String: Any])?["sub-1"] as? [String: Any]
        )

        #expect(revert["mailboxIds/scheduled"] is NSNull)
        #expect(revert["mailboxIds/drafts"] as? Bool == true)
    }

    @Test("Cancelling reverts the message through onSuccessUpdateEmail, not a second call")
    func cancelRevertsOnSuccess() throws {
        let arguments = JMAPClient.cancelArguments(
            accountID: "u1",
            submissionID: "sub-1",
            draftsMailboxID: "drafts",
            fileInMailboxID: "sent"
        )

        let update = arguments["update"] as? [String: Any]
        #expect((update?["sub-1"] as? [String: Any])?["undoStatus"] as? String == "canceled")

        // The revert is keyed by the same submission id, so it only runs if the
        // cancel did — a separate Email/set would run regardless.
        let onSuccess = try #require(arguments["onSuccessUpdateEmail"] as? [String: Any])
        let revert = onSuccess["sub-1"] as? [String: Any]

        #expect(revert?["keywords/$draft"] as? Bool == true)
        #expect(revert?["mailboxIds/drafts"] as? Bool == true)
        #expect(revert?["mailboxIds/sent"] is NSNull)
    }

    @Test("Without a Sent mailbox the cancel touches only Drafts")
    func cancelWithoutSentMailbox() {
        let arguments = JMAPClient.cancelArguments(
            accountID: "u1",
            submissionID: "sub-1",
            draftsMailboxID: "drafts",
            fileInMailboxID: nil
        )

        let onSuccess = arguments["onSuccessUpdateEmail"] as? [String: Any]
        let revert = onSuccess?["sub-1"] as? [String: Any]

        #expect(revert?["mailboxIds/drafts"] as? Bool == true)
        #expect(revert?.count == 2)
    }

    // MARK: - The banner's lifetime

    @Test("The release phrasing counts down while it can, then names the day")
    func releasePhrasing() {
        func pending(_ offset: TimeInterval) -> PendingSend {
            PendingSend(
                submissionID: "sub-1",
                subject: "Hello",
                fileInMailboxID: "scheduled",
                sendAt: now.addingTimeInterval(offset),
                now: now
            )
        }

        #expect(pending(8).releaseDescription(at: now) == "in 8 seconds")
        // Never a negative countdown: the banner can outlive the release by a
        // tick before its task clears it.
        #expect(pending(-3).releaseDescription(at: now) == "in 0 seconds")
        #expect(pending(86_400).releaseDescription(at: now).hasPrefix("on "))
    }

    @Test("A schedule days out still only offers a short undo window")
    func bannerWindowIsCapped() {
        let pending = PendingSend(
            submissionID: "sub-1",
            subject: "Hello",
            fileInMailboxID: "scheduled",
            sendAt: now.addingTimeInterval(86_400),
            now: now
        )

        #expect(pending.undoUntil == now.addingTimeInterval(PendingSend.maxBannerWindow))
    }

    @Test("An undo-window send offers undo right up to release")
    func bannerMatchesShortHold() {
        let pending = PendingSend(
            submissionID: "sub-1",
            subject: "Hello",
            fileInMailboxID: "scheduled",
            sendAt: now.addingTimeInterval(10),
            now: now
        )

        #expect(pending.undoUntil == pending.sendAt)
    }
}

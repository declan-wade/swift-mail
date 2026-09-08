import Foundation
import SwiftUI
import Combine
import AppKit

/// Which mailboxes post a local notification when new mail lands in them.
///
/// Fastmail's server-side rules file mail straight into folders, and JMAP
/// exposes no per-mailbox "notify me" flag, so the choice is kept locally as a
/// comma-separated list of mailbox ids. The Inbox is seeded on first run;
/// after that an empty list genuinely means "notify me about nothing".
nonisolated enum NotifyingMailboxes {
    static let storageKey = "swift-mail.notifyingMailboxIDs"

    static func ids(in list: String) -> Set<String> {
        Set(list.split(separator: ",").compactMap { $0.trimmingCharacters(in: .whitespaces).nilIfEmpty })
    }

    static func list(from ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static var current: Set<String> {
        ids(in: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// First launch only: match what the app did before this setting existed.
    static func seedIfNeeded(inboxID: String?, defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil, let inboxID else {
            return
        }

        defaults.set(inboxID, forKey: storageKey)
    }
}

/// How the reader treats the message it opens.
nonisolated enum ReadingPreferences {
    /// Off (the default) keeps the explicit Mark as Read button as the only way
    /// a message loses its unread state.
    static let marksReadOnOpenKey = "swift-mail.marksReadOnOpen"

    static var marksReadOnOpen: Bool {
        UserDefaults.standard.bool(forKey: marksReadOnOpenKey)
    }
}

@MainActor
final class MailStore: ObservableObject {
    @Published var account: MailAccount?
    @Published var mailboxes: [Mailbox] = []
    @Published var selectedMailboxID: Mailbox.ID?
    @Published var emails: [EmailPreview] = []
    @Published var selectedEmailID: EmailPreview.ID?
    @Published var selectedEmail: EmailDetail?
    @Published var isLoadingMailboxes = false
    @Published var isLoadingEmails = false
    @Published var isLoadingMoreEmails = false
    @Published var isLoadingSelectedEmail = false
    @Published var updatingReadStateEmailIDs: Set<EmailPreview.ID> = []
    @Published var updatingFlagEmailIDs: Set<EmailPreview.ID> = []
    @Published var movingEmailIDs: Set<EmailPreview.ID> = []
    @Published var identities: [MailIdentity] = []
    /// Modal-alert error for discrete, user-initiated actions (send, flag,
    /// archive, manual refresh). Background and column-scoped failures use the
    /// dedicated properties below so they don't interrupt the user.
    @Published var errorMessage: String?
    /// Inline banner for auto-fetch failures.
    @Published var backgroundErrorMessage: String?
    /// Inline state for the message-list column.
    @Published var emailsErrorMessage: String?
    /// Inline state for the reader column.
    @Published var detailErrorMessage: String?
    /// The live search query. Empty means the plain mailbox listing.
    @Published var searchText = ""
    @Published var hasMoreEmails = false

    @Published private var session: JMAPSession?
    private var accountID: String?
    private var bearerToken: String?
    private var autoFetchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// The last-seen server state per JMAP type, so background syncs ask the
    /// server only for what changed (`Email/changes`) instead of re-querying.
    private var emailState: String?
    private var mailboxState: String?
    private var hasWiredNotificationHandler = false
    private let notificationService = NotificationService.shared

    private let emailPageSize = 50
    /// Cap on `Email/changes` pages walked in one sync, so a pathological
    /// change backlog can't spin here indefinitely.
    private let maxChangePages = 25

    /// The query the currently displayed `emails` were fetched with, so
    /// background refreshes and load-more stay consistent with what's on screen.
    private var activeSearch: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The active query as a JMAP filter, scoped to `mailboxID` unless the
    /// query says otherwise with `in:`.
    private func searchFilter(mailboxID: Mailbox.ID) -> [String: Any]? {
        guard let activeSearch else {
            return nil
        }

        return SearchQuery(activeSearch).jmapFilter(mailboxID: mailboxID, mailboxes: mailboxes)
    }

    /// Autocomplete for the search field, derived from the mailboxes and
    /// messages already loaded.
    var searchSuggestions: [SearchQuery.Suggestion] {
        SearchQuery.suggestions(for: searchText, mailboxes: mailboxes, emails: emails)
    }

    private let accountStorageKey = "swift-mail.account"

    var selectedMailbox: Mailbox? {
        mailboxes.first { $0.id == selectedMailboxID }
    }

    /// Capability URNs the connected server advertises, for the Settings list.
    var serverCapabilities: [String] {
        session?.capabilityURNs.sorted() ?? []
    }

    var supportsSnooze: Bool {
        session?.supports(JMAPCapability.snoozeURN) ?? false
    }

    var hasConfiguredAccount: Bool {
        account != nil && bearerToken?.isEmpty == false
    }

    var defaultIdentity: MailIdentity? {
        identities.first
    }

    func identity(id: String?) -> MailIdentity? {
        guard let id else {
            return defaultIdentity
        }

        return identities.first { $0.id == id } ?? defaultIdentity
    }

    func mailbox(role: String) -> Mailbox? {
        mailboxes.first { $0.role == role }
    }

    init() {
        loadSavedAccount()
    }

    func saveAccount(displayName: String, sessionURL: URL, bearerToken: String) throws {
        let account = MailAccount(displayName: displayName, sessionURL: sessionURL)
        let data = try JSONEncoder().encode(account)

        UserDefaults.standard.set(data, forKey: accountStorageKey)
        try KeychainStore.saveToken(bearerToken)

        self.account = account
        self.bearerToken = bearerToken
        session = nil
        accountID = nil
        emailState = nil
        mailboxState = nil
        mailboxes = []
        emails = []
        selectedEmail = nil
        selectedMailboxID = nil
        selectedEmailID = nil
        stopAutoFetch()
        updateDockBadge()
    }

    func removeAccount() {
        stopAutoFetch()
        UserDefaults.standard.removeObject(forKey: accountStorageKey)
        try? KeychainStore.deleteToken()

        account = nil
        bearerToken = nil
        session = nil
        accountID = nil
        emailState = nil
        mailboxState = nil
        mailboxes = []
        emails = []
        selectedEmail = nil
        selectedMailboxID = nil
        selectedEmailID = nil
        updateDockBadge()
    }

    func refresh() async {
        guard let account, let bearerToken else {
            return
        }

        isLoadingMailboxes = true
        errorMessage = nil

        do {
            let client = JMAPClient(sessionURL: account.sessionURL, bearerToken: bearerToken)
            let session = try await client.fetchSession()
            guard let accountID = session.mailAccountID else {
                throw JMAPError.missingMailAccount
            }

            let mailboxes = try await client.fetchMailboxes(session: session, accountID: accountID)
            self.session = session
            self.accountID = accountID
            self.mailboxes = mailboxes
            NotifyingMailboxes.seedIfNeeded(inboxID: mailboxes.first { $0.role == "inbox" }?.id)
            updateDockBadge()

            let inboxID = mailboxes.first { $0.role == "inbox" }?.id ?? mailboxes.first?.id
            selectedMailboxID = selectedMailboxID ?? inboxID
            await seedSyncStates()
            startAutoFetchIfNeeded(session: session)
            await loadIdentities()

            if let selectedMailboxID {
                await loadEmails(mailboxID: selectedMailboxID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingMailboxes = false
    }

    func loadEmails(mailboxID: Mailbox.ID) async {
        guard let client = makeClient(), let session, let accountID else {
            await refresh()
            return
        }

        // Switching mailboxes abandons any in-progress search.
        if mailboxID != selectedMailboxID, !searchText.isEmpty {
            searchTask?.cancel()
            searchText = ""
        }

        selectedMailboxID = mailboxID
        isLoadingEmails = true
        selectedEmail = nil
        selectedEmailID = nil
        emailsErrorMessage = nil
        detailErrorMessage = nil
        hasMoreEmails = false

        do {
            let page = try await client.fetchEmailPreviews(
                session: session,
                accountID: accountID,
                mailboxID: mailboxID,
                position: 0,
                limit: emailPageSize,
                searchFilter: searchFilter(mailboxID: mailboxID)
            )

            emails = page.previews
            applyPageMetadata(page)
            selectedEmailID = emails.first?.id

            if let selectedEmailID {
                await loadEmailDetail(emailID: selectedEmailID)
            }
        } catch {
            emails = []
            emailsErrorMessage = error.localizedDescription
        }

        isLoadingEmails = false
    }

    /// Appends the next page of the current mailbox/search listing.
    func loadMoreEmails() async {
        guard hasMoreEmails,
              !isLoadingEmails,
              !isLoadingMoreEmails,
              let client = makeClient(),
              let session,
              let accountID,
              let mailboxID = selectedMailboxID else {
            return
        }

        isLoadingMoreEmails = true
        let search = activeSearch
        let nextPosition = emails.count

        do {
            let page = try await client.fetchEmailPreviews(
                session: session,
                accountID: accountID,
                mailboxID: mailboxID,
                position: nextPosition,
                limit: emailPageSize,
                searchFilter: searchFilter(mailboxID: mailboxID)
            )

            // Guard against a mailbox/search switch that landed mid-request.
            guard selectedMailboxID == mailboxID, activeSearch == search else {
                isLoadingMoreEmails = false
                return
            }

            let known = Set(emails.map(\.id))
            emails.append(contentsOf: page.previews.filter { !known.contains($0.id) })
            applyPageMetadata(page)
        } catch {
            emailsErrorMessage = error.localizedDescription
        }

        isLoadingMoreEmails = false
    }

    /// Debounced entry point for the search field.
    func searchQueryChanged(_ text: String) {
        searchText = text
        searchTask?.cancel()

        guard let mailboxID = selectedMailboxID else {
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }

            await self?.loadEmails(mailboxID: mailboxID)
        }
    }

    private func applyPageMetadata(_ page: JMAPClient.EmailPreviewPage) {
        if let total = page.total {
            hasMoreEmails = emails.count < total
        } else {
            hasMoreEmails = page.previews.count >= emailPageSize
        }
    }

    func loadEmailDetail(emailID: EmailPreview.ID) async {
        guard let client = makeClient(), let session, let accountID else {
            return
        }

        selectedEmailID = emailID
        isLoadingSelectedEmail = true
        detailErrorMessage = nil

        do {
            selectedEmail = try await client.fetchEmailDetail(session: session, accountID: accountID, emailID: emailID)
        } catch {
            detailErrorMessage = error.localizedDescription
        }

        isLoadingSelectedEmail = false

        // Every path that opens a message in the reader lands here, so this is
        // the one place the "read on open" preference has to be honoured.
        if ReadingPreferences.marksReadOnOpen,
           selectedEmailID == emailID,
           selectedEmail?.isUnread == true {
            await setReadState(emailID: emailID, isRead: true)
        }
    }

    func setReadState(emailID: EmailPreview.ID, isRead: Bool) async {
        guard !updatingReadStateEmailIDs.contains(emailID),
              let client = makeClient(),
              let session,
              let accountID else {
            return
        }

        let previousEmail = emails.first { $0.id == emailID }
        let wasUnread = previousEmail?.isUnread ?? selectedEmail?.isUnread ?? false

        updatingReadStateEmailIDs.insert(emailID)
        errorMessage = nil

        do {
            try await client.setEmailSeen(session: session, accountID: accountID, emailID: emailID, isSeen: isRead)
            applyReadState(emailID: emailID, isRead: isRead, wasUnread: wasUnread)
        } catch {
            errorMessage = error.localizedDescription
        }

        updatingReadStateEmailIDs.remove(emailID)
    }

    func toggleReadState(emailID: EmailPreview.ID) async {
        let isUnread = emails.first { $0.id == emailID }?.isUnread ?? selectedEmail?.isUnread ?? false
        await setReadState(emailID: emailID, isRead: isUnread)
    }

    func toggleFlag(emailID: EmailPreview.ID) async {
        guard !updatingFlagEmailIDs.contains(emailID),
              let client = makeClient(),
              let session,
              let accountID else {
            return
        }

        let wasFlagged = emails.first { $0.id == emailID }?.isFlagged ?? selectedEmail?.isFlagged ?? false
        let isFlagged = !wasFlagged

        updatingFlagEmailIDs.insert(emailID)
        errorMessage = nil

        do {
            try await client.setEmailKeyword(session: session, accountID: accountID, emailID: emailID, keyword: "$flagged", isSet: isFlagged)
            applyFlagState(emailID: emailID, isFlagged: isFlagged)
        } catch {
            errorMessage = error.localizedDescription
        }

        updatingFlagEmailIDs.remove(emailID)
    }

    /// Moves an email to the mailbox for `role` (`"archive"` or `"trash"`) and,
    /// on success, advances the list selection so the detail pane doesn't go
    /// blank. Mirrors `setReadState`'s optimistic-update-then-roll-back shape.
    func moveEmail(emailID: EmailPreview.ID, toRole role: String) async {
        guard !movingEmailIDs.contains(emailID),
              let client = makeClient(),
              let session,
              let accountID else {
            return
        }

        guard let destination = mailbox(role: role) else {
            errorMessage = JMAPError.missingMailbox(role.capitalized).localizedDescription
            return
        }

        movingEmailIDs.insert(emailID)
        errorMessage = nil

        do {
            try await client.moveEmail(session: session, accountID: accountID, emailID: emailID, toMailboxID: destination.id)
            applyMove(emailID: emailID)
        } catch {
            errorMessage = error.localizedDescription
        }

        movingEmailIDs.remove(emailID)
    }

    func archive(emailID: EmailPreview.ID) async {
        await moveEmail(emailID: emailID, toRole: "archive")
    }

    func delete(emailID: EmailPreview.ID) async {
        await moveEmail(emailID: emailID, toRole: "trash")
    }

    // MARK: - Compose

    /// Identities are optional: an account without submission support can still
    /// read mail, so a failure here is not surfaced as a mail error.
    func loadIdentities() async {
        guard let client = makeClient(), let session else {
            return
        }

        guard let submissionAccountID = session.submissionAccountID else {
            return
        }

        identities = (try? await client.fetchIdentities(session: session, accountID: submissionAccountID)) ?? []
    }

    /// Saves the draft to the Drafts mailbox. Errors propagate so the compose
    /// window can report them inline instead of interrupting the main window.
    @discardableResult
    func saveDraft(_ draft: ComposeDraft) async throws -> String {
        let context = try await apiContext()

        guard let draftsMailboxID = mailbox(role: "drafts")?.id else {
            throw JMAPError.missingMailbox("Drafts")
        }

        let emailID = try await context.client.createDraft(
            session: context.session,
            accountID: context.accountID,
            draft: draft,
            identity: try requireIdentity(for: draft),
            draftsMailboxID: draftsMailboxID
        )

        await discardResumedDraft(draft, context: context)
        await refreshIfViewing(mailboxRole: "drafts")
        return emailID
    }

    /// Removes the pre-edit copy of a resumed draft. Best-effort: a failure here
    /// must not fail the save/send that already succeeded.
    private func discardResumedDraft(
        _ draft: ComposeDraft,
        context: (client: JMAPClient, session: JMAPSession, accountID: String)
    ) async {
        guard let sourceDraftID = draft.sourceDraftID else {
            return
        }

        try? await context.client.destroyEmail(
            session: context.session,
            accountID: context.accountID,
            emailID: sourceDraftID
        )

        if selectedEmail?.id == sourceDraftID {
            selectedEmail = nil
            selectedEmailID = nil
        }
        emails.removeAll { $0.id == sourceDraftID }
    }

    func send(_ draft: ComposeDraft) async throws {
        let context = try await apiContext()

        guard let draftsMailboxID = mailbox(role: "drafts")?.id else {
            throw JMAPError.missingMailbox("Drafts")
        }

        try await context.client.send(
            session: context.session,
            accountID: context.accountID,
            submissionAccountID: context.session.submissionAccountID ?? context.accountID,
            draft: draft,
            identity: try requireIdentity(for: draft),
            draftsMailboxID: draftsMailboxID,
            sentMailboxID: mailbox(role: "sent")?.id
        )

        await discardResumedDraft(draft, context: context)

        if let originalEmailID = draft.originalEmailID, selectedEmail?.id == originalEmailID {
            await loadEmailDetail(emailID: originalEmailID)
        }

        await refreshIfViewing(mailboxRole: "sent")
    }

    private func requireIdentity(for draft: ComposeDraft) throws -> MailIdentity {
        guard let identity = identity(id: draft.identityID) else {
            throw JMAPError.missingIdentity
        }

        return identity
    }

    // MARK: - Attachments

    /// Downloads an attachment to a private temporary file, for Quick Look.
    func previewFile(for attachment: EmailAttachment) async throws -> URL {
        let data = try await attachmentData(attachment)
        // A per-download directory keeps the real filename (Quick Look picks
        // its previewer from the extension) without ever colliding.
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: Self.safeFileName(for: attachment))
        try data.write(to: file)

        return file
    }

    /// Saves an attachment into ~/Downloads, numbering the name if it is taken.
    @discardableResult
    func saveToDownloads(_ attachment: EmailAttachment) async throws -> URL {
        let data = try await attachmentData(attachment)
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let file = Self.uniqueURL(in: downloads, named: Self.safeFileName(for: attachment))
        try data.write(to: file)

        return file
    }

    private func attachmentData(_ attachment: EmailAttachment) async throws -> Data {
        let context = try await apiContext()

        return try await context.client.downloadBlob(
            session: context.session,
            accountID: context.accountID,
            attachment: attachment
        )
    }

    /// The sender picks the attachment name, so it is reduced to a single, plain
    /// path component before it is ever joined to a directory.
    nonisolated static func safeFileName(for attachment: EmailAttachment) -> String {
        let component = (attachment.displayName as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(component.drop { $0 == "." }).nilIfEmpty ?? "attachment"
    }

    /// "report.pdf" taken becomes "report 2.pdf", then "report 3.pdf".
    nonisolated static func uniqueURL(in directory: URL, named name: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let candidate = directory.appending(path: name)
        guard exists(candidate) else {
            return candidate
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        for suffix in 2...999 {
            let numbered = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let url = directory.appending(path: numbered)
            if !exists(url) {
                return url
            }
        }

        return directory.appending(path: "\(base) \(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
    }

    /// Compose can be triggered before the first refresh has landed, so this
    /// establishes the session on demand rather than failing.
    private func apiContext() async throws -> (client: JMAPClient, session: JMAPSession, accountID: String) {
        if session == nil {
            await refresh()
        }

        guard let client = makeClient(), let session, let accountID else {
            throw JMAPError.missingMailAccount
        }

        return (client, session, accountID)
    }

    private func refreshIfViewing(mailboxRole: String) async {
        guard let mailboxID = mailbox(role: mailboxRole)?.id, selectedMailboxID == mailboxID else {
            return
        }

        await loadEmails(mailboxID: mailboxID)
    }

    func stopAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = nil
    }

    private func makeClient() -> JMAPClient? {
        guard let account, let bearerToken else {
            return nil
        }

        return JMAPClient(sessionURL: account.sessionURL, bearerToken: bearerToken)
    }

    // MARK: - Background sync

    /// Records the current server state so the first background sync has a
    /// baseline to diff against, and won't treat the whole mailbox as "new".
    private func seedSyncStates() async {
        guard let client = makeClient(), let session, let accountID else {
            return
        }

        if let states = try? await client.fetchTypeStates(session: session, accountID: accountID) {
            emailState = states.email
            mailboxState = states.mailbox
        }
    }

    private func startAutoFetchIfNeeded(session: JMAPSession) {
        guard autoFetchTask == nil, let bearerToken else {
            return
        }

        wireNotificationHandlerIfNeeded()

        Task {
            await notificationService.requestAuthorizationIfNeeded()
        }

        autoFetchTask = Task { [weak self] in
            guard let self else {
                return
            }

            if let eventSourceURL = session.eventSourceURL(types: ["Email", "Mailbox"]) {
                await self.runEventSourceLoop(eventSourceURL: eventSourceURL, bearerToken: bearerToken)
            } else {
                await self.runPollingLoop()
            }
        }
    }

    /// Consumes the JMAP push stream. Each `StateChange` carries the new state
    /// per type; the connection is re-established after the server closes it
    /// (`closeafter`) or a transport error, with a capped exponential backoff.
    private func runEventSourceLoop(eventSourceURL: URL, bearerToken: String) async {
        var backoff = Duration.seconds(1)

        while !Task.isCancelled {
            do {
                let eventSource = JMAPEventSource(url: eventSourceURL, bearerToken: bearerToken)
                for try await change in eventSource.events() {
                    try Task.checkCancellation()
                    backoff = .seconds(1)
                    await applyStateChange(change)
                }

                // A clean end is the server's `closeafter` — reconnect at once
                // and reconcile anything missed while off the wire.
                try Task.checkCancellation()
                await syncNow()
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(120))
            }
        }
    }

    /// Fallback for servers that don't advertise an event source: poll the
    /// cheap type-state endpoint and only do real work when something moved.
    private func runPollingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else {
                return
            }

            await syncNow()
        }
    }

    /// Polls current type states and reconciles anything that changed.
    private func syncNow() async {
        guard let client = makeClient(), let session, let accountID else {
            return
        }

        do {
            let states = try await client.fetchTypeStates(session: session, accountID: accountID)

            if let mailbox = states.mailbox, mailbox != mailboxState {
                await syncMailboxes(newState: mailbox)
            }

            if let email = states.email, email != emailState {
                await syncEmailChanges(newState: email)
            }
        } catch {
            backgroundErrorMessage = error.localizedDescription
        }
    }

    private func applyStateChange(_ change: JMAPStateChange) async {
        guard let accountID else {
            return
        }

        if let mailbox = change.state(for: "Mailbox", accountID: accountID), mailbox != mailboxState {
            await syncMailboxes(newState: mailbox)
        }

        if let email = change.state(for: "Email", accountID: accountID), email != emailState {
            await syncEmailChanges(newState: email)
        }
    }

    /// Re-reads mailboxes for their counts (drives the sidebar and the dock
    /// badge). Cheap enough to do wholesale on any `Mailbox` state change.
    private func syncMailboxes(newState: String) async {
        guard let client = makeClient(), let session, let accountID else {
            return
        }

        do {
            mailboxes = try await client.fetchMailboxes(session: session, accountID: accountID)
            mailboxState = newState
            NotifyingMailboxes.seedIfNeeded(inboxID: mailboxes.first { $0.role == "inbox" }?.id)
            updateDockBadge()
        } catch {
            backgroundErrorMessage = error.localizedDescription
        }
    }

    /// Walks `Email/changes` from the last-seen state and applies only the
    /// deltas. Falls back to a full reload of the visible list if the server
    /// can't answer incrementally (`cannotCalculateChanges`) or anything else
    /// goes wrong — without firing notifications, to avoid a stale burst.
    private func syncEmailChanges(newState: String) async {
        guard let client = makeClient(), let session, let accountID else {
            return
        }

        guard let since = emailState else {
            emailState = newState
            return
        }

        do {
            var cursor = since
            var created: [String] = []
            var updated: [String] = []
            var destroyed: [String] = []

            for _ in 0..<maxChangePages {
                let changes = try await client.fetchEmailChanges(
                    session: session,
                    accountID: accountID,
                    sinceState: cursor
                )

                created += changes.created
                updated += changes.updated.filter { !changes.created.contains($0) }
                destroyed += changes.destroyed
                cursor = changes.newState

                if !changes.hasMoreChanges {
                    break
                }
            }

            let destroyedSet = Set(destroyed)
            let createdSet = Set(created).subtracting(destroyedSet)
            let toFetch = Array(createdSet.union(updated).subtracting(destroyedSet)).prefix(100)

            let previews = try await client.fetchEmailPreviews(
                session: session,
                accountID: accountID,
                ids: Array(toFetch)
            )

            emailState = cursor
            applyEmailDeltas(previews: previews, createdIDs: createdSet, destroyedIDs: destroyedSet)
        } catch {
            emailState = newState
            await reloadVisibleList()
        }
    }

    /// Merges an incremental `Email` delta into the visible list and posts
    /// notifications for genuinely new Inbox mail.
    private func applyEmailDeltas(
        previews: [EmailPreview],
        createdIDs: Set<String>,
        destroyedIDs: Set<String>
    ) {
        // Destroyed messages leave every list, and the selection with them.
        if !destroyedIDs.isEmpty {
            let hadSelection = selectedEmailID.map(destroyedIDs.contains) ?? false
            emails.removeAll { destroyedIDs.contains($0.id) }
            if hadSelection {
                selectedEmailID = emails.first?.id
                if let selectedEmailID {
                    Task { await loadEmailDetail(emailID: selectedEmailID) }
                } else {
                    selectedEmail = nil
                }
            }
        }

        let inboxID = mailboxes.first { $0.role == "inbox" }?.id
        let byID = Dictionary(previews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Updated messages already on screen: refresh in place so read/flag
        // changes made on another device show up live.
        emails = emails.map { byID[$0.id] ?? $0 }

        // Keep the open message's read/flag state in step with other devices.
        if let selectedEmailID, let refreshed = byID[selectedEmailID], selectedEmail != nil {
            selectedEmail = selectedEmail?
                .settingSeen(!refreshed.isUnread)
                .settingFlagged(refreshed.isFlagged)
        }

        // New messages belonging to the currently displayed mailbox drop in at
        // the top (the list is sorted newest-first) if not already present.
        if let selectedMailboxID, activeSearch == nil {
            let known = Set(emails.map(\.id))
            let additions = previews
                .filter { createdIDs.contains($0.id) && $0.mailboxIds?[selectedMailboxID] == true && !known.contains($0.id) }
                .sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }
            emails.insert(contentsOf: additions, at: 0)
        }

        // Notifications: new, unread, recent mail in any mailbox the user has
        // switched on in Settings. Grouped per mailbox so the notification can
        // name the folder the message was filed into.
        let notifying = NotifyingMailboxes.current
        for mailbox in mailboxes where notifying.contains(mailbox.id) {
            let notifiable = previews.filter {
                createdIDs.contains($0.id) && $0.warrantsNotification(mailboxID: mailbox.id)
            }

            if !notifiable.isEmpty {
                let name = mailbox.displayName
                Task {
                    await notificationService.notifyNewMessages(notifiable, mailboxName: name)
                }
            }
        }
    }

    /// Rebuilds the visible mailbox listing after an incremental sync bailed,
    /// preserving the user's selection and scroll depth.
    private func reloadVisibleList() async {
        guard let client = makeClient(),
              let session,
              let accountID,
              let mailboxID = selectedMailboxID,
              activeSearch == nil else {
            return
        }

        do {
            let page = try await client.fetchEmailPreviews(
                session: session,
                accountID: accountID,
                mailboxID: mailboxID,
                limit: max(emailPageSize, emails.count)
            )

            guard selectedMailboxID == mailboxID, activeSearch == nil else {
                return
            }

            let previousSelection = selectedEmailID
            emails = page.previews
            applyPageMetadata(page)

            if let previousSelection, page.previews.contains(where: { $0.id == previousSelection }) {
                selectedEmailID = previousSelection
            } else {
                selectedEmailID = page.previews.first?.id
            }
        } catch {
            backgroundErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Dock badge

    /// Mirrors the Inbox unread count onto the dock icon, matching Mail.
    private func updateDockBadge() {
        let unread = mailboxes.first { $0.role == "inbox" }?.unreadEmails ?? 0
        NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
    }

    // MARK: - Notification actions

    private func wireNotificationHandlerIfNeeded() {
        guard !hasWiredNotificationHandler else {
            return
        }

        hasWiredNotificationHandler = true
        notificationService.actionHandler = { [weak self] action in
            Task { await self?.handleNotificationAction(action) }
        }
    }

    private func handleNotificationAction(_ action: NotificationService.Action) async {
        switch action {
        case .open(let emailID):
            await openFromNotification(emailID: emailID)
        case .markRead(let emailID):
            await setReadState(emailID: emailID, isRead: true)
            notificationService.clearNotifications(for: [emailID])
        case .archive(let emailID):
            await moveEmail(emailID: emailID, toRole: "archive")
            notificationService.clearNotifications(for: [emailID])
        case .trash(let emailID):
            await moveEmail(emailID: emailID, toRole: "trash")
            notificationService.clearNotifications(for: [emailID])
        }
    }

    private func openFromNotification(emailID: EmailPreview.ID) async {
        notificationService.clearNotifications(for: [emailID])

        if session == nil {
            await refresh()
        }

        if let inboxID = mailboxes.first(where: { $0.role == "inbox" })?.id, selectedMailboxID != inboxID {
            await loadEmails(mailboxID: inboxID)
        }

        selectedEmailID = emailID
        await loadEmailDetail(emailID: emailID)
    }

    private func applyReadState(emailID: EmailPreview.ID, isRead: Bool, wasUnread: Bool) {
        emails = emails.map { email in
            guard email.id == emailID else {
                return email
            }

            return email.settingSeen(isRead)
        }

        if selectedEmail?.id == emailID {
            selectedEmail = selectedEmail?.settingSeen(isRead)
        }

        if isRead {
            notificationService.clearNotifications(for: [emailID])
        }

        updateSelectedMailboxUnreadCount(wasUnread: wasUnread, isUnread: !isRead)
    }

    private func applyFlagState(emailID: EmailPreview.ID, isFlagged: Bool) {
        emails = emails.map { email in
            guard email.id == emailID else {
                return email
            }

            return email.settingFlagged(isFlagged)
        }

        if selectedEmail?.id == emailID {
            selectedEmail = selectedEmail?.settingFlagged(isFlagged)
        }
    }

    /// Removes the email from the currently displayed list and, if it was
    /// selected, advances to its neighbor rather than leaving the reading
    /// pane empty.
    private func applyMove(emailID: EmailPreview.ID) {
        let wasSelected = selectedEmailID == emailID
        let removedIndex = emails.firstIndex { $0.id == emailID }

        emails.removeAll { $0.id == emailID }

        guard wasSelected else {
            return
        }

        guard let removedIndex, !emails.isEmpty else {
            selectedEmailID = nil
            selectedEmail = nil
            return
        }

        let nextIndex = min(removedIndex, emails.count - 1)
        let nextEmailID = emails[nextIndex].id
        selectedEmailID = nextEmailID

        Task {
            await loadEmailDetail(emailID: nextEmailID)
        }
    }

    private func updateSelectedMailboxUnreadCount(wasUnread: Bool, isUnread: Bool) {
        guard wasUnread != isUnread, let selectedMailboxID else {
            return
        }

        mailboxes = mailboxes.map { mailbox in
            guard mailbox.id == selectedMailboxID else {
                return mailbox
            }

            let currentUnread = mailbox.unreadEmails ?? 0
            let adjustedUnread = max(0, currentUnread + (isUnread ? 1 : -1))

            return Mailbox(
                id: mailbox.id,
                name: mailbox.name,
                role: mailbox.role,
                parentId: mailbox.parentId,
                sortOrder: mailbox.sortOrder,
                totalEmails: mailbox.totalEmails,
                unreadEmails: adjustedUnread
            )
        }

        updateDockBadge()
    }

    private func loadSavedAccount() {
        if let data = UserDefaults.standard.data(forKey: accountStorageKey) {
            account = try? JSONDecoder().decode(MailAccount.self, from: data)
        }

        bearerToken = try? KeychainStore.loadToken()
    }
}

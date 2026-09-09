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

/// How long the server holds a message before releasing it.
///
/// Send later and undo send are the same mechanism — an `EmailSubmission` with
/// a `sendAt` in the future, cancellable until then — so they share one
/// setting and one code path. Nothing is held locally: the hold is the
/// server's, which is why it survives quitting the app.
nonisolated enum SendPreferences {
    /// Seconds. `0` (the default, and what `UserDefaults` returns for an unset
    /// key) means send immediately, matching what the app did before this
    /// existed.
    static let undoDelayKey = "swift-mail.undoSendDelay"

    static let undoDelayChoices = [0, 5, 10, 30]

    static var undoDelay: Int {
        UserDefaults.standard.integer(forKey: undoDelayKey)
    }

    /// The `sendAt` to ask for, or nil to send immediately.
    ///
    /// An explicit request wins over the undo delay — scheduling for Monday
    /// shouldn't also wait ten seconds — and both are clamped to what the
    /// server said it would hold, since asking for longer is rejected outright
    /// rather than shortened.
    static func releaseDate(
        requested: Date?,
        undoDelay: Int,
        maxDelayedSend: Int,
        now: Date = Date()
    ) -> Date? {
        guard maxDelayedSend > 0 else {
            return nil
        }

        let wanted = requested ?? (undoDelay > 0 ? now.addingTimeInterval(TimeInterval(undoDelay)) : nil)

        // A date already in the past is a schedule the user let lapse; send now
        // rather than have the server refuse it.
        guard let wanted, wanted > now else {
            return nil
        }

        return min(wanted, now.addingTimeInterval(TimeInterval(maxDelayedSend)))
    }
}

/// The times a message can be scheduled for without opening a date picker.
///
/// Every case resolves against a real calendar rather than an offset in hours,
/// so "tomorrow morning" lands at 8am tomorrow whatever time it is now, and
/// stays right across a daylight-saving change.
nonisolated enum SendLaterPreset: String, CaseIterable, Identifiable {
    case thisEvening
    case tomorrowMorning
    case mondayMorning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisEvening: "This Evening"
        case .tomorrowMorning: "Tomorrow Morning"
        case .mondayMorning: "Monday Morning"
        }
    }

    /// `nil` when the moment has already passed today — an evening send offered
    /// at 11pm would otherwise mean "eighteen hours ago".
    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .thisEvening:
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now).flatMap { $0 > now ? $0 : nil }
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
                return nil
            }

            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        case .mondayMorning:
            // `nextDate` skips today, so a Monday-morning send made on Monday
            // means next Monday rather than a time that may already be gone.
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 8, minute: 0, second: 0, weekday: 2),
                matchingPolicy: .nextTime
            )
        }
    }

    /// The presets this server will actually accept, in order. A cap of a few
    /// hours quietly leaves only the near ones rather than offering a Monday
    /// the send would be rejected for.
    static func available(from now: Date, within maxDelayedSend: Int, calendar: Calendar = .current) -> [(preset: SendLaterPreset, date: Date)] {
        let latest = now.addingTimeInterval(TimeInterval(maxDelayedSend))

        return allCases.compactMap { preset in
            guard let date = preset.date(from: now, calendar: calendar), date <= latest else {
                return nil
            }

            return (preset, date)
        }
    }
}

/// A message the server is still holding, and how long the app will keep
/// offering to call it back.
nonisolated struct PendingSend: Equatable {
    let submissionID: String
    let subject: String
    /// The mailbox the send filed it into — Scheduled where the account has
    /// one. Undo needs it to know what to take the message back out of.
    let fileInMailboxID: String?
    /// When the server releases it.
    let sendAt: Date
    /// When the undo banner gives up. Equal to `sendAt` for an undo-window
    /// send; capped for a schedule further out, where a banner is the wrong
    /// place to keep the offer alive.
    let undoUntil: Date

    /// A banner is a transient thing. Past this, cancelling a scheduled message
    /// wants a list of what is queued.
    // ponytail: no scheduled-messages list; `EmailSubmission/query` filtered on
    // undoStatus "pending" is the upgrade path when one is wanted.
    static let maxBannerWindow: TimeInterval = 30

    /// When this message goes, phrased for the reader: seconds while the hold
    /// is short enough to count down, a date once counting down reads as
    /// absurd. Shared so the banner and the quit warning can't drift apart.
    func releaseDescription(at now: Date = Date()) -> String {
        let seconds = Int(sendAt.timeIntervalSince(now).rounded())

        guard seconds > 60 else {
            return "in \(max(0, seconds)) seconds"
        }

        return "on \(sendAt.formatted(date: .abbreviated, time: .shortened))"
    }

    init(
        submissionID: String,
        subject: String,
        fileInMailboxID: String?,
        sendAt: Date,
        now: Date = Date()
    ) {
        self.submissionID = submissionID
        self.subject = subject
        self.fileInMailboxID = fileInMailboxID
        self.sendAt = sendAt
        self.undoUntil = min(sendAt, now.addingTimeInterval(Self.maxBannerWindow))
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
    /// The colour-coded tags the account's aliases are grouped into. Empty is
    /// the default, and an empty list means the app behaves exactly as it did
    /// before tags existed — no chips, no labels, no narrowing.
    @Published var tags: [MailTag] = [] {
        didSet {
            guard tags != oldValue else {
                return
            }

            TagPreferences.save(tags)

            // Deleting the tag the window was narrowed to has to lift the
            // narrowing too, or the list stays filtered by something the user
            // can no longer see or switch off.
            if let activeTagID, !tags.contains(where: { $0.id == activeTagID }) {
                self.activeTagID = nil
                return
            }

            // Only an alias change alters which messages the active tag
            // matches; a rename or a recolour repaints the rows already on
            // screen without going back to the server.
            if addresses(ofTagID: activeTagID, in: tags) != addresses(ofTagID: activeTagID, in: oldValue) {
                reloadForTagChange()
            }
        }
    }

    /// The tag every folder is currently narrowed to — the separated inbox —
    /// or nil for the unified view every untagged account gets.
    @Published var activeTagID: MailTag.ID? {
        didSet {
            guard activeTagID != oldValue else {
                return
            }

            TagPreferences.saveActiveID(activeTagID)
            reloadForTagChange()
        }
    }
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
    /// Every message in the open message's conversation, oldest first. Holds a
    /// single element for a message with no siblings, which the reader treats
    /// as "no conversation to show".
    @Published var conversation: [EmailPreview] = []
    /// Changes made here that the server hasn't accepted yet. Non-zero means
    /// the app is holding work for a connection it doesn't have.
    @Published private(set) var pendingOutboxCount = 0

    /// The send currently offered for undo, if any.
    @Published private(set) var pendingSend: PendingSend?
    private var undoWindowTask: Task<Void, Never>?

    @Published private var session: JMAPSession?
    private var accountID: String?
    private var bearerToken: String?
    private var autoFetchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// The mailbox the messages currently on screen were fetched for, which is
    /// not the same as the selected one while a switch is in flight.
    private var loadedMailboxID: Mailbox.ID?
    /// The message whose body is being fetched right now, so the same fetch
    /// isn't started twice concurrently.
    private var loadingDetailEmailID: EmailPreview.ID?
    /// The conversation currently in `conversation`, so switching between
    /// messages of the same thread doesn't refetch it.
    private var loadedThreadID: String?
    private var conversationTask: Task<Void, Never>?
    /// The last-seen server state per JMAP type, so background syncs ask the
    /// server only for what changed (`Email/changes`) instead of re-querying.
    private var emailState: String?
    private var mailboxState: String?
    private let cache = MailCache.shared
    private var isDrainingOutbox = false
    private var hasWiredNotificationHandler = false
    private let notificationService = NotificationService.shared

    private let emailPageSize = 50
    /// Cap on `Email/changes` pages walked in one sync, so a pathological
    /// change backlog can't spin here indefinitely.
    private let maxChangePages = 25
    /// How many times a change may be refused before it is dropped rather than
    /// retried forever. Only server answers count towards this; being offline
    /// never does.
    private static let maxOutboxAttempts = 5

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

    /// The filter behind the message list: the search query, narrowed again to
    /// the active tag's aliases. `fetchEmailPreviews` reads a nil filter as
    /// "this mailbox", so the mailbox condition is spelled out here the moment
    /// a tag has to be ANDed alongside it.
    private func listFilter(mailboxID: Mailbox.ID) -> [String: Any]? {
        let search = searchFilter(mailboxID: mailboxID)

        guard let tagCondition = activeTag?.jmapCondition else {
            return search
        }

        return ["operator": "AND", "conditions": [search ?? ["inMailbox": mailboxID], tagCondition]]
    }

    func isActive(_ filter: SearchQuery.QuickFilter) -> Bool {
        SearchQuery.contains(filter.rawValue, in: searchText)
    }

    /// Quick filters live in the search text itself, so they reuse the whole
    /// existing query path — debounce, JMAP filter, paging — and stack with a
    /// typed query rather than fighting it.
    func toggle(_ filter: SearchQuery.QuickFilter) {
        searchQueryChanged(SearchQuery.toggling(filter.rawValue, in: searchText))
    }

    var hasQuickFilter: Bool {
        SearchQuery.QuickFilter.allCases.contains(where: isActive)
    }

    /// True when the query is *only* quick filters, so the empty state can say
    /// "nothing matches" instead of quoting `is:unread` back at the user.
    var isFilteredWithoutSearchTerms: Bool {
        let tokens = SearchQuery.tokenize(searchText)

        return !tokens.isEmpty && tokens.allSatisfy { token in
            SearchQuery.QuickFilter.allCases.contains { $0.rawValue.caseInsensitiveCompare(token) == .orderedSame }
        }
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

    /// Capabilities this account may actually use, which is where a server can
    /// put a feature it doesn't advertise server-wide.
    var accountCapabilities: [String] {
        session?.accountCapabilityURNs(accountID: accountID).sorted() ?? []
    }

    /// Server limits worth showing, as label/value pairs.
    var serverLimits: [(label: String, value: String)] {
        guard let limits = session?.coreLimits else {
            return []
        }

        func bytes(_ value: Int?) -> String? {
            value.map { Int64($0).formatted(.byteCount(style: .file)) }
        }

        return [
            ("Objects per set", limits.maxObjectsInSet?.formatted()),
            ("Objects per get", limits.maxObjectsInGet?.formatted()),
            ("Calls per request", limits.maxCallsInRequest?.formatted()),
            ("Max request size", bytes(limits.maxSizeRequest)),
            ("Max upload size", bytes(limits.maxSizeUpload))
        ].compactMap { label, value in value.map { (label, $0) } }
    }

    /// Seconds this account may hold a submission for. `0` means the server
    /// won't hold anything, so neither send later nor undo send is offered.
    var maxDelayedSend: Int {
        session?.maxDelayedSend(accountID: session?.submissionAccountID ?? accountID) ?? 0
    }

    var supportsDelayedSend: Bool {
        maxDelayedSend > 0
    }

    var supportsSnooze: Bool {
        session?.supports(JMAPCapability.snoozeURN, accountID: accountID) ?? false
    }

    var hasConfiguredAccount: Bool {
        account != nil && bearerToken?.isEmpty == false
    }

    /// Whether this launch still has to reach the server. A restored snapshot
    /// fills `mailboxes` before any request, so "is the mailbox list empty" no
    /// longer answers "do we need to connect".
    var needsInitialRefresh: Bool {
        session == nil
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

    var activeTag: MailTag? {
        tags.first { $0.id == activeTagID }
    }

    /// Whether a message belongs in the list as it is currently narrowed. A
    /// tag with no aliases yet narrows nothing, matching the query the server
    /// is actually being sent.
    private func matchesActiveTag(_ email: EmailPreview) -> Bool {
        guard let tag = activeTag, !tag.addresses.isEmpty else {
            return true
        }

        return tag.matches(email)
    }

    private func addresses(ofTagID id: MailTag.ID?, in tags: [MailTag]) -> [String]? {
        tags.first { $0.id == id }?.addresses
    }

    /// Adds a tag already named and coloured, so the common case is one click
    /// and no decisions.
    /// Every address the Tags pane offers.
    ///
    /// Sending identities are the convenient starting point, not the boundary:
    /// anything already assigned to a tag stays listed, which is what keeps a
    /// hand-typed address — an external Outlook or Gmail account, an alias this
    /// account only receives at — visible once it has been added.
    var taggableAddresses: [String] {
        let assigned = tags.flatMap(\.addresses)
        let known = identities.map(\.email) + assigned

        return Array(Set(known.map { $0.lowercased() })).sorted()
    }

    func addTag() {
        tags.append(
            MailTag(
                name: MailTag.suggestedName(existing: tags),
                color: MailTag.suggestedColor(existing: tags)
            )
        )
    }

    func removeTag(id: MailTag.ID) {
        tags.removeAll { $0.id == id }
    }

    /// Moves one alias onto `tagID`, or off every tag when nil. An alias
    /// belongs to at most one tag, so this rewrites the whole list in a single
    /// assignment rather than removing here and adding there.
    func assignAddress(_ address: String, toTagID tagID: MailTag.ID?) {
        let address = address.lowercased()

        tags = tags.map { tag in
            var tag = tag
            tag.addresses.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }

            if tag.id == tagID {
                tag.addresses.append(address)
            }

            return tag
        }
    }

    private func reloadForTagChange() {
        guard let mailboxID = selectedMailboxID else {
            return
        }

        Task { await loadEmails(mailboxID: mailboxID) }
    }

    init() {
        loadSavedAccount()

        // Assignments in an initializer skip `didSet`, so restoring these
        // neither re-saves them nor kicks off a load before there is an
        // account to load from.
        tags = TagPreferences.load()
        let restored = TagPreferences.loadActiveID()
        activeTagID = tags.contains { $0.id == restored } ? restored : nil

        restoreFromCache()
    }

    /// Identifies the snapshot's owner. The JMAP account id would be better but
    /// isn't known until a session is fetched, and this has to work before the
    /// first request.
    private static func accountKey(for account: MailAccount) -> String {
        "\(account.sessionURL.absoluteString)|\(account.displayName)"
    }

    /// Fills the first frame from the last session's mail. Everything restored
    /// here is replaced by the first successful sync, so this only ever changes
    /// how quickly the window has something in it — never what it settles on.
    private func restoreFromCache() {
        guard let account else {
            return
        }

        cache.open(accountKey: Self.accountKey(for: account))

        mailboxes = cache.mailboxes()
        identities = cache.identities()
        selectedMailboxID = cache.selectedMailboxID()

        // The cursors are the point of the whole cache: restoring them is what
        // lets the first sync of this launch ask for a delta rather than
        // re-querying the mailbox from scratch.
        emailState = cache.syncState(for: "Email")
        mailboxState = cache.syncState(for: "Mailbox")
        pendingOutboxCount = cache.pendingOutbox().count

        guard let selectedMailboxID else {
            return
        }

        let page = cache.page(mailboxID: selectedMailboxID, limit: emailPageSize)
        guard !page.isEmpty else {
            return
        }

        emails = page
        selectedEmailID = page.first?.id
        // `loadedMailboxID` has to agree, or the reload `refresh()` starts a
        // moment later reads as a folder switch and clears these rows straight
        // back to a skeleton.
        loadedMailboxID = selectedMailboxID
    }

    /// Mirrors what is on screen into the cache. Only the plain folder listing
    /// is stored: a search or tag page would come back next launch looking like
    /// the whole folder.
    private func cacheVisibleList() {
        cache.setSyncState(emailState, for: "Email")
        cache.setSyncState(mailboxState, for: "Mailbox")
        cache.setSelectedMailboxID(selectedMailboxID)

        guard activeSearch == nil, activeTag == nil else {
            return
        }

        cache.store(previews: emails)
    }

    /// The cached page is the unfiltered folder listing, so it is only safe to
    /// show while nothing is narrowing the list.
    private func cachedPage(for mailboxID: Mailbox.ID) -> [EmailPreview] {
        guard activeSearch == nil, activeTag == nil else {
            return []
        }

        return cache.page(mailboxID: mailboxID, limit: emailPageSize)
    }

    func saveAccount(displayName: String, sessionURL: URL, bearerToken: String) throws {
        let account = MailAccount(displayName: displayName, sessionURL: sessionURL)
        let data = try JSONEncoder().encode(account)

        UserDefaults.standard.set(data, forKey: accountStorageKey)
        try KeychainStore.saveToken(bearerToken)
        cache.reset(accountKey: Self.accountKey(for: account))

        self.account = account
        self.bearerToken = bearerToken
        session = nil
        accountID = nil
        emailState = nil
        mailboxState = nil
        mailboxes = []
        emails = []
        loadedMailboxID = nil
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
        // Signing out has to take the cached mail with it.
        cache.clear()

        account = nil
        bearerToken = nil
        session = nil
        accountID = nil
        emailState = nil
        mailboxState = nil
        mailboxes = []
        emails = []
        loadedMailboxID = nil
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
            cache.setMailboxes(mailboxes)
            cache.setIdentities(identities)

            // Reconnecting is the moment anything queued while offline can go.
            await drainOutbox()

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

        // `selectedMailboxID` is no use for spotting a folder change: the
        // sidebar's selection binding has already written the new id before
        // `onChange` gets here. Comparing against the folder the on-screen
        // messages actually came from is what distinguishes a genuine switch
        // from a re-query of the same folder (search, refresh, retry).
        if mailboxID != loadedMailboxID {
            // A search or filter follows the user from folder to folder;
            // leaving one is a deliberate act, never a side effect of clicking
            // a different mailbox. The pending debounce still has to go: it
            // captured the *old* folder and would reload it over this one a
            // moment later. The query itself is re-applied below.
            searchTask?.cancel()

            // The previous folder's messages have to go, or they sit there
            // looking like this folder's. Where a cached page exists it stands
            // in until the query lands; otherwise this empties the list and the
            // skeleton shows, as before.
            emails = cachedPage(for: mailboxID)
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
                searchFilter: listFilter(mailboxID: mailboxID)
            )

            emails = page.previews
            applyPageMetadata(page)
            loadedMailboxID = mailboxID
            selectedEmailID = emails.first?.id
            cacheVisibleList()

            // The list has what it needs now; the reader's fetch is a separate
            // wait and shouldn't hold the message list behind the skeleton.
            isLoadingEmails = false

            if let selectedEmailID {
                await loadEmailDetail(emailID: selectedEmailID)
            }
        } catch {
            emails = []
            loadedMailboxID = mailboxID
            emailsErrorMessage = error.localizedDescription
            isLoadingEmails = false
        }
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
                searchFilter: listFilter(mailboxID: mailboxID)
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
        // SwiftUI writes the current value straight back through a `searchable`
        // binding when the field is focused and again when it is dismissed.
        // Without this guard each of those no-op writes scheduled a full
        // mailbox reload, which cleared the list selection and re-fetched the
        // open message — and swallowed the first Escape, so the field appeared
        // to need dismissing twice.
        guard text != searchText else {
            return
        }

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
        // Assigning `selectedEmailID` below trips the list's `onChange`, which
        // asks for the very fetch this call just started — two round trips for
        // one message on every load. Collapsing them needs an *in-flight*
        // guard rather than an "already loaded" one: the reader's Try Again
        // re-requests a message that failed, and that has to get through.
        guard loadingDetailEmailID != emailID else {
            return
        }

        guard let client = makeClient(), let session, let accountID else {
            return
        }

        loadingDetailEmailID = emailID
        defer { loadingDetailEmailID = nil }

        if selectedEmail?.id != emailID {
            inlineImageCache.removeAll()
        }

        loadConversation(for: emailID)

        selectedEmailID = emailID
        detailErrorMessage = nil

        // A message body is immutable, so a cached one is not "stale data shown
        // while we check" — it is the answer. The fetch behind it is only for
        // the parts that aren't in the cache yet.
        let cached = cache.body(for: emailID)
        selectedEmail = cached
        isLoadingSelectedEmail = cached == nil

        do {
            let detail = try await client.fetchEmailDetail(session: session, accountID: accountID, emailID: emailID)
            cache.store(body: detail)

            // The reader may have moved on while this was in flight; writing the
            // cache is still worth it, but the screen isn't ours to change.
            if selectedEmailID == emailID {
                selectedEmail = detail
            }
        } catch {
            // A cached body already on screen is a better answer than an error
            // banner over the top of it.
            if cached == nil {
                detailErrorMessage = error.localizedDescription
            }
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
        let wasUnread = emails.first { $0.id == emailID }?.isUnread ?? selectedEmail?.isUnread ?? false
        guard wasUnread == isRead else {
            return
        }

        errorMessage = nil
        applyReadState(emailID: emailID, isRead: isRead, wasUnread: wasUnread)
        cacheOptimistic(emailID: emailID) { $0.settingSeen(isRead) }
        enqueue(.keyword("$seen", isSet: isRead), for: emailID)

        await drainOutbox()
    }

    func toggleReadState(emailID: EmailPreview.ID) async {
        let isUnread = emails.first { $0.id == emailID }?.isUnread ?? selectedEmail?.isUnread ?? false
        await setReadState(emailID: emailID, isRead: isUnread)
    }

    func toggleFlag(emailID: EmailPreview.ID) async {
        let wasFlagged = emails.first { $0.id == emailID }?.isFlagged ?? selectedEmail?.isFlagged ?? false
        let isFlagged = !wasFlagged

        errorMessage = nil
        applyFlagState(emailID: emailID, isFlagged: isFlagged)
        cacheOptimistic(emailID: emailID) { $0.settingFlagged(isFlagged) }
        enqueue(.keyword("$flagged", isSet: isFlagged), for: emailID)

        await drainOutbox()
    }

    /// Moves an email to the mailbox for `role` (`"archive"` or `"trash"`) and,
    /// on success, advances the list selection so the detail pane doesn't go
    /// blank. Mirrors `setReadState`'s optimistic-update-then-roll-back shape.
    func moveEmail(emailID: EmailPreview.ID, toRole role: String) async {
        guard let destination = mailbox(role: role) else {
            errorMessage = JMAPError.missingMailbox(role.capitalized).localizedDescription
            return
        }

        errorMessage = nil
        cacheOptimistic(emailID: emailID) { $0.settingMailbox(destination.id) }
        applyMove(emailID: emailID)
        enqueue(.move(mailboxID: destination.id), for: emailID)

        await drainOutbox()
    }

    // MARK: - Outbox

    /// Records a change the user has already seen applied, so the obligation to
    /// send it survives a failed request, a quit, and a flat network.
    private func enqueue(_ action: OutboxEntry.Action, for emailID: EmailPreview.ID) {
        cache.enqueue(OutboxEntry(emailID: emailID, action: action))
        pendingOutboxCount = cache.pendingOutbox().count
    }

    /// Mirrors an optimistic change into the cache, so a relaunch before the
    /// send lands shows what the user did rather than what the server last said.
    private func cacheOptimistic(emailID: EmailPreview.ID, _ change: (EmailPreview) -> EmailPreview) {
        guard let current = emails.first(where: { $0.id == emailID }) ?? cache.message(id: emailID) else {
            return
        }

        cache.store(previews: [change(current)])
    }

    /// Server truth with this session's un-sent changes laid back on top.
    ///
    /// This is the ordering rule the whole outbox rests on: `Email/changes` is
    /// the only writer of server state, the outbox is the only writer to the
    /// server, and where they disagree the outbox wins until it drains.
    /// Without this, a delta computed before a pending archive puts the message
    /// back in the list a moment after the user archived it.
    private func applyingPending(to preview: EmailPreview) -> EmailPreview {
        cache.pendingOutbox(for: preview.id).reduce(preview) { $1.apply(to: $0) }
    }

    /// Sends what is owed, oldest first, stopping at the first entry the
    /// network refuses so a flat connection doesn't burn through the queue.
    func drainOutbox() async {
        guard !isDrainingOutbox else {
            return
        }

        let pending = cache.pendingOutbox()
        guard !pending.isEmpty else {
            pendingOutboxCount = 0
            return
        }

        // No session means offline, not rejected. Leaving the queue untouched
        // is what keeps `attempts` a count of the server's refusals rather than
        // a count of how long the user was on a train.
        guard let client = makeClient(), let session, let accountID else {
            pendingOutboxCount = pending.count
            return
        }

        isDrainingOutbox = true
        defer { isDrainingOutbox = false }

        for entry in pending {
            markInFlight(entry, true)

            do {
                try await send(entry, client: client, session: session, accountID: accountID)
                cache.removeOutbox(id: entry.id)
            } catch {
                markInFlight(entry, false)

                guard Self.isWorthRetrying(error), entry.attempts + 1 < Self.maxOutboxAttempts else {
                    // The server's final word, or a change that has been refused
                    // too often to keep. Drop it and put the screen back to the
                    // truth rather than leaving a change that will never land.
                    cache.removeOutbox(id: entry.id)
                    errorMessage = error.localizedDescription
                    await rollBack(entry)
                    continue
                }

                cache.recordOutboxAttempt(id: entry.id)
                // Ordering matters — a later change to the same message must not
                // overtake this one — so the drain stops here and retries on the
                // next refresh, push, or mutation.
                break
            }

            markInFlight(entry, false)
        }

        pendingOutboxCount = cache.pendingOutbox().count
    }

    private func send(_ entry: OutboxEntry, client: JMAPClient, session: JMAPSession, accountID: String) async throws {
        switch entry.action {
        case .keyword(let keyword, let isSet):
            try await client.setEmailKeyword(
                session: session,
                accountID: accountID,
                emailID: entry.emailID,
                keyword: keyword,
                isSet: isSet
            )
        case .move(let mailboxID):
            try await client.moveEmail(
                session: session,
                accountID: accountID,
                emailID: entry.emailID,
                toMailboxID: mailboxID
            )
        }
    }

    /// A rejection is the server's final answer; anything that never reached it
    /// is worth another go. An unrecognised failure is retried, but counted, so
    /// a poison entry can't wedge the queue forever.
    private static func isWorthRetrying(_ error: Error) -> Bool {
        switch error {
        case JMAPError.setError, JMAPError.methodError, JMAPError.emailNotFound:
            false
        case JMAPError.httpStatus(let code, _):
            code == 429 || (500...599).contains(code)
        default:
            true
        }
    }

    /// Puts the screen back to the truth after a change the server refused.
    /// A keyword is reversed in place; a move has to rebuild the list, because
    /// the message was taken out of it and belongs back at its own date.
    private func rollBack(_ entry: OutboxEntry) async {
        if let server = try? await refetch(emailID: entry.emailID) {
            cache.store(previews: [applyingPending(to: server)])
        }

        switch entry.action {
        case .keyword("$seen", let isSet):
            let wasUnread = !isSet
            applyReadState(emailID: entry.emailID, isRead: !isSet, wasUnread: wasUnread)
        case .keyword("$flagged", let isSet):
            applyFlagState(emailID: entry.emailID, isFlagged: !isSet)
        case .keyword:
            break
        case .move:
            await reloadVisibleList()
        }
    }

    private func refetch(emailID: EmailPreview.ID) async throws -> EmailPreview? {
        guard let client = makeClient(), let session, let accountID else {
            return nil
        }

        return try await client.fetchEmailPreviews(session: session, accountID: accountID, ids: [emailID]).first
    }

    private func markInFlight(_ entry: OutboxEntry, _ isInFlight: Bool) {
        func update(_ set: inout Set<EmailPreview.ID>) {
            if isInFlight {
                set.insert(entry.emailID)
            } else {
                set.remove(entry.emailID)
            }
        }

        switch entry.action {
        case .keyword("$seen", _): update(&updatingReadStateEmailIDs)
        case .keyword("$flagged", _): update(&updatingFlagEmailIDs)
        case .keyword: break
        case .move: update(&movingEmailIDs)
        }
    }

    func archive(emailID: EmailPreview.ID) async {
        await moveEmail(emailID: emailID, toRole: "archive")
    }

    func delete(emailID: EmailPreview.ID) async {
        await moveEmail(emailID: emailID, toRole: "trash")
    }

    // MARK: - Sweep

    /// What a sweep would touch: the first page for the user to look at, and
    /// the server's count of the whole match.
    struct SweepPreview {
        let previews: [EmailPreview]
        let total: Int?
    }

    /// Hard ceiling on one sweep. A runaway query shouldn't be able to move an
    /// entire account in a single click, and stopping short is recoverable
    /// where moving 50,000 messages is not.
    /// ponytail: fixed cap; make it a prompt ("sweep the first 5,000?") if
    /// anyone actually hits it.
    private static let sweepLimit = 5_000
    /// Ids per `Email/query` page while gathering the match set.
    private static let sweepPageSize = 250
    /// Fallback when the server doesn't advertise a limit. RFC 8620 2 suggests
    /// a minimum of 500 for `maxObjectsInSet`, so this is deliberately timid.
    private static let fallbackSetBatchSize = 100
    /// Upper bound regardless of what the server allows, so one `Email/set`
    /// stays a sane request rather than a single enormous one.
    private static let maxSetBatchSize = 500

    /// How many updates to put in one `Email/set`, from the server's own
    /// `maxObjectsInSet` rather than a guess.
    private var sweepBatchSize: Int {
        min(session?.coreLimits?.maxObjectsInSet ?? Self.fallbackSetBatchSize, Self.maxSetBatchSize)
    }

    /// The filter a sweep would run, or nil if the query is empty. An empty
    /// query must never mean "everything in this folder".
    nonisolated static func sweepFilter(query: String, mailboxID: Mailbox.ID?, mailboxes: [Mailbox]) -> [String: Any]? {
        guard let mailboxID else {
            return nil
        }

        // The guard is on what the query *parses to*, not on whether the string
        // looks blank. `""` is two characters and trims to two characters, but
        // tokenizes to nothing — and a query of no terms leaves a filter of
        // nothing but `inMailbox`, which is the whole folder.
        let parsed = SearchQuery(query)
        guard !parsed.terms.isEmpty else {
            return nil
        }

        return parsed.jmapFilter(mailboxID: mailboxID, mailboxes: mailboxes)
    }

    private func sweepFilter(query: String) -> [String: Any]? {
        guard let filter = Self.sweepFilter(query: query, mailboxID: selectedMailboxID, mailboxes: mailboxes) else {
            return nil
        }

        // A sweep run while a tag is active stays inside that tag. What the
        // user approved was a preview of the tag's mail, and a bulk move is
        // the last place to quietly touch more than was shown.
        guard let tagCondition = activeTag?.jmapCondition else {
            return filter
        }

        return ["operator": "AND", "conditions": [filter, tagCondition]]
    }

    func previewSweep(query: String) async throws -> SweepPreview {
        guard let client = makeClient(), let session, let accountID,
              let mailboxID = selectedMailboxID, let filter = sweepFilter(query: query) else {
            return SweepPreview(previews: [], total: 0)
        }

        let page = try await client.fetchEmailPreviews(
            session: session,
            accountID: accountID,
            mailboxID: mailboxID,
            position: 0,
            limit: emailPageSize,
            searchFilter: filter
        )

        return SweepPreview(previews: page.previews, total: page.total)
    }

    /// Moves every message matching `query` into `mailboxID`. Returns how many
    /// actually moved.
    func performSweep(query: String, toMailboxID mailboxID: String) async throws -> Int {
        guard let client = makeClient(), let session, let accountID,
              let filter = sweepFilter(query: query) else {
            return 0
        }

        // The whole id set is collected *before* anything moves. Moving as we
        // page would shift every later position out from under us, because the
        // messages we just moved drop out of the query's own results.
        var ids: [String] = []
        var seen: Set<String> = []
        var position = 0

        while ids.count < Self.sweepLimit {
            let page = try await client.fetchEmailIDs(
                session: session,
                accountID: accountID,
                searchFilter: filter,
                position: position,
                limit: Self.sweepPageSize
            )

            // Mail arriving mid-page shifts every later position down, which
            // hands back an id we already have. Page by a position that counts
            // what the server returned, and keep only ids we haven't seen.
            position += page.ids.count
            ids += page.ids.filter { seen.insert($0).inserted }

            if page.ids.count < Self.sweepPageSize {
                break
            }
        }

        var moved = 0
        let batchSize = sweepBatchSize

        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            let refused = try await client.moveEmails(
                session: session,
                accountID: accountID,
                emailIDs: batch,
                toMailboxID: mailboxID
            )

            moved += batch.count - refused.count
        }

        if moved > 0 {
            await refresh()
        }

        return moved
    }

    // MARK: - Conversations

    /// Loads the thread around `emailID`, if it isn't already loaded.
    ///
    /// Deliberately not awaited by `loadEmailDetail`: the body is what the
    /// reader is waiting for, and the conversation strip can arrive a moment
    /// later without holding it up.
    private func loadConversation(for emailID: EmailPreview.ID) {
        guard let threadID = emails.first(where: { $0.id == emailID })?.threadId
            ?? conversation.first(where: { $0.id == emailID })?.threadId else {
            conversation = []
            loadedThreadID = nil
            return
        }

        guard threadID != loadedThreadID else {
            return
        }

        conversationTask?.cancel()
        loadedThreadID = threadID
        conversation = []

        guard let client = makeClient(), let session, let accountID else {
            return
        }

        conversationTask = Task { [weak self] in
            let emails = try? await client.fetchThreadEmails(session: session, accountID: accountID, threadID: threadID)

            guard let self, !Task.isCancelled, loadedThreadID == threadID else {
                return
            }

            conversation = emails ?? []
        }
    }

    // MARK: - Inline images

    /// Bytes already fetched for the open message, keyed by blob id. Cleared
    /// when a different message is opened, which is what bounds it.
    /// ponytail: whole-message cache; make it an LRU if a single message with
    /// very large inline parts ever matters.
    private var inlineImageCache: [String: Data] = [:]

    /// Fetches one inline part by Content-ID, for the reader's `cid:` handler.
    func inlineImage(cid: String, in email: EmailDetail) async -> (data: Data, mimeType: String)? {
        let wanted = Self.normalizedContentID(cid)

        guard let attachment = (email.attachments ?? []).first(where: {
            $0.cid.map(Self.normalizedContentID) == wanted
        }), let blobID = attachment.blobId else {
            return nil
        }

        // Only images are served. A `cid:` part is an inline image in practice,
        // and handing the web view whatever type a sender declared would let a
        // crafted message get, say, text/html rendered from an attachment.
        let type = attachment.type ?? ""
        guard type.lowercased().hasPrefix("image/") else {
            return nil
        }

        if let cached = inlineImageCache[blobID] {
            return (cached, type)
        }

        guard let client = makeClient(), let session, let accountID,
              let data = try? await client.downloadBlob(session: session, accountID: accountID, attachment: attachment) else {
            return nil
        }

        inlineImageCache[blobID] = data

        return (data, type)
    }

    /// Fetches one blob by id for the compose preview, where the parts come
    /// from a forwarded message rather than from the open one.
    func blobForPreview(blobID: String, type: String) async -> (data: Data, mimeType: String)? {
        guard type.lowercased().hasPrefix("image/") else {
            return nil
        }

        if let cached = inlineImageCache[blobID] {
            return (cached, type)
        }

        guard let client = makeClient(), let session, let accountID,
              let data = try? await client.downloadBlob(
                session: session,
                accountID: accountID,
                attachment: EmailAttachment(blobId: blobID, type: type, name: nil, size: nil, disposition: nil, cid: nil)
              ) else {
            return nil
        }

        inlineImageCache[blobID] = data

        return (data, type)
    }

    /// Content-IDs appear with or without angle brackets depending on the
    /// sender, while the `cid:` URL never carries them.
    nonisolated static func normalizedContentID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }

    // MARK: - Attachments

    /// Uploads one file and returns it ready to attach. Throws rather than
    /// reporting through `errorMessage` so the compose window — which owns its
    /// own draft and its own error surface — decides how to tell the user.
    func uploadAttachment(data: Data, name: String, type: String) async throws -> ComposeAttachment {
        guard let client = makeClient(), let session, let accountID else {
            throw JMAPError.missingMailAccount
        }

        // The server states its own ceiling; refusing here beats a failed
        // upload after pushing the whole file over the wire.
        if let limit = session.coreLimits?.maxSizeUpload, data.count > limit {
            throw JMAPError.attachmentTooLarge(name, limit)
        }

        let blob = try await client.uploadBlob(session: session, accountID: accountID, data: data, type: type)

        return ComposeAttachment(
            blobId: blob.blobId,
            name: name,
            type: blob.type ?? type,
            size: blob.size ?? data.count
        )
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

    /// - Parameter sendAt: an explicit time to release the message. Left nil,
    ///   the undo-send delay decides — so an ordinary send is still held long
    ///   enough to be called back when that preference is on.
    func send(_ draft: ComposeDraft, sendAt: Date? = nil) async throws {
        let context = try await apiContext()

        guard let draftsMailboxID = mailbox(role: "drafts")?.id else {
            throw JMAPError.missingMailbox("Drafts")
        }

        let releaseAt = SendPreferences.releaseDate(
            requested: sendAt,
            undoDelay: SendPreferences.undoDelay,
            maxDelayedSend: maxDelayedSend
        )

        // Only a time the user actually asked for counts as scheduling; the
        // automatic undo hold does not, and files to Sent as it always has.
        let fileInMailboxID = filingMailboxID(isScheduled: sendAt != nil && releaseAt != nil)

        let submissionID = try await context.client.send(
            session: context.session,
            accountID: context.accountID,
            submissionAccountID: context.session.submissionAccountID ?? context.accountID,
            draft: draft,
            identity: try requireIdentity(for: draft),
            draftsMailboxID: draftsMailboxID,
            fileInMailboxID: fileInMailboxID,
            sendAt: releaseAt
        )

        await discardResumedDraft(draft, context: context)

        if let originalEmailID = draft.originalEmailID, selectedEmail?.id == originalEmailID {
            await loadEmailDetail(emailID: originalEmailID)
        }

        await refreshIfViewing(mailboxID: fileInMailboxID)

        // The message id isn't carried: `onSuccessUpdateEmail` resolves it from
        // the submission, so the submission id is the whole handle on the undo.
        if let releaseAt, let submissionID {
            beginUndoWindow(
                PendingSend(
                    submissionID: submissionID,
                    subject: draft.windowTitle,
                    fileInMailboxID: fileInMailboxID,
                    sendAt: releaseAt
                )
            )
        }
    }

    /// Where a sent message is filed.
    ///
    /// A message the user scheduled hasn't been sent yet, so it belongs in the
    /// account's own Scheduled queue rather than in Sent, where it would read
    /// as already gone. Sent is the fallback for an account without that
    /// mailbox.
    ///
    /// The few seconds of an undo hold deliberately don't route here. Nobody
    /// thinks of pressing Send as scheduling, and it keeps the ordinary send
    /// path on the behaviour it has always had — which matters while it is
    /// unconfirmed whether the server files a released message into Sent
    /// itself. If it does, this can widen to every held send.
    private func filingMailboxID(isScheduled: Bool) -> String? {
        if isScheduled, let scheduled = mailbox(role: "scheduled")?.id {
            return scheduled
        }

        return mailbox(role: "sent")?.id
    }

    /// Recalls the held message: cancels the submission and, only if that
    /// worked, puts the message back in Drafts.
    func undoSend() async {
        guard let pending = pendingSend else {
            return
        }

        // Cleared first: the offer is spent either way, and leaving the banner
        // up during the round trip invites a second tap on a submission that is
        // already being cancelled.
        clearUndoWindow()

        do {
            let context = try await apiContext()

            guard let draftsMailboxID = mailbox(role: "drafts")?.id else {
                throw JMAPError.missingMailbox("Drafts")
            }

            try await context.client.cancelSubmission(
                session: context.session,
                submissionAccountID: context.session.submissionAccountID ?? context.accountID,
                submissionID: pending.submissionID,
                draftsMailboxID: draftsMailboxID,
                fileInMailboxID: pending.fileInMailboxID
            )

            await refreshIfViewing(mailboxID: pending.fileInMailboxID)
            await refreshIfViewing(mailboxRole: "drafts")
        } catch {
            // The window is narrow and the race is real: the server may have
            // released the message between the banner being drawn and the tap.
            errorMessage = "The message could not be recalled: \(error.localizedDescription)"
        }
    }

    private func beginUndoWindow(_ pending: PendingSend) {
        undoWindowTask?.cancel()
        pendingSend = pending

        undoWindowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, pending.undoUntil.timeIntervalSinceNow)))

            guard !Task.isCancelled else {
                return
            }

            await self?.expireUndoWindow(submissionID: pending.submissionID)
        }
    }

    /// Only clears the banner it was started for: a second send during the
    /// first one's window replaces `pendingSend`, and the older timer must not
    /// then dismiss the newer offer.
    private func expireUndoWindow(submissionID: String) {
        guard pendingSend?.submissionID == submissionID else {
            return
        }

        pendingSend = nil
    }

    func clearUndoWindow() {
        undoWindowTask?.cancel()
        undoWindowTask = nil
        pendingSend = nil
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
        if let blobID = attachment.blobId, let cached = cache.blob(for: blobID) {
            return cached
        }

        let context = try await apiContext()
        let data = try await context.client.downloadBlob(
            session: context.session,
            accountID: context.accountID,
            attachment: attachment
        )

        if let blobID = attachment.blobId {
            // Attachments are the one write here big enough to be worth keeping
            // off the main actor.
            let cache = cache
            Task.detached(priority: .utility) {
                cache.store(blob: data, for: blobID)
            }
        }

        return data
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
        await refreshIfViewing(mailboxID: mailbox(role: mailboxRole)?.id)
    }

    private func refreshIfViewing(mailboxID: Mailbox.ID?) async {
        guard let mailboxID, selectedMailboxID == mailboxID else {
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
        // A cursor restored from the snapshot is the entire reason to keep one.
        // Overwriting it with the server's current state would silently discard
        // every change that landed while the app was closed — the first sync
        // would diff against now and find nothing.
        guard emailState == nil || mailboxState == nil else {
            return
        }

        guard let client = makeClient(), let session, let accountID else {
            return
        }

        if let states = try? await client.fetchTypeStates(session: session, accountID: accountID) {
            emailState = emailState ?? states.email
            mailboxState = mailboxState ?? states.mailbox
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

                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(120))
            }

            // Reconcile on every disconnect, clean or failed. State changes are
            // edge-triggered, so anything that happened while off the wire is
            // only ever seen by asking. Reconciling here also means a server
            // that refuses the stream outright degrades into polling at the
            // backoff interval instead of going quiet.
            guard !Task.isCancelled else {
                return
            }

            await syncNow()
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

        // The push loop doubles as the retry tick: a queue held back by a
        // transient failure gets another go without a timer of its own.
        await drainOutbox()
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
            cache.setMailboxes(mailboxes)
            cache.setSyncState(mailboxState, for: "Mailbox")
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

            // The server's view, corrected by anything still queued here. A
            // delta computed before a pending archive would otherwise put the
            // message back in the list a moment after the user archived it.
            let reconciled = previews.map { applyingPending(to: $0) }

            applyEmailDeltas(previews: reconciled, createdIDs: createdSet, destroyedIDs: destroyedSet)
            cache.remove(emailIDs: destroyedSet)
            cache.store(previews: reconciled)
            // Without this the on-disk cursor goes stale while the app stays
            // open, and a long-running session still relaunches into a big diff.
            cacheVisibleList()
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
                .filter {
                    createdIDs.contains($0.id)
                        && $0.mailboxIds?[selectedMailboxID] == true
                        && !known.contains($0.id)
                        && matchesActiveTag($0)
                }
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
                limit: max(emailPageSize, emails.count),
                searchFilter: listFilter(mailboxID: mailboxID)
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

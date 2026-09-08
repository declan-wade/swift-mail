import Foundation
import SwiftUI
import Combine

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
    @Published var isLoadingSelectedEmail = false
    @Published var updatingReadStateEmailIDs: Set<EmailPreview.ID> = []
    @Published var updatingFlagEmailIDs: Set<EmailPreview.ID> = []
    @Published var movingEmailIDs: Set<EmailPreview.ID> = []
    @Published var identities: [MailIdentity] = []
    @Published var errorMessage: String?

    private var session: JMAPSession?
    private var accountID: String?
    private var bearerToken: String?
    private var autoFetchTask: Task<Void, Never>?
    private var knownInboxEmailIDs: Set<EmailPreview.ID> = []
    private var hasLoadedInitialInboxSnapshot = false
    private let notificationService = NotificationService()

    private let accountStorageKey = "swift-mail.account"

    var selectedMailbox: Mailbox? {
        mailboxes.first { $0.id == selectedMailboxID }
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
        mailboxes = []
        emails = []
        selectedEmail = nil
        selectedMailboxID = nil
        selectedEmailID = nil
        stopAutoFetch()
    }

    func removeAccount() {
        stopAutoFetch()
        UserDefaults.standard.removeObject(forKey: accountStorageKey)
        try? KeychainStore.deleteToken()

        account = nil
        bearerToken = nil
        session = nil
        accountID = nil
        mailboxes = []
        emails = []
        selectedEmail = nil
        selectedMailboxID = nil
        selectedEmailID = nil
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

            let inboxID = mailboxes.first { $0.role == "inbox" }?.id ?? mailboxes.first?.id
            selectedMailboxID = selectedMailboxID ?? inboxID
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

        selectedMailboxID = mailboxID
        isLoadingEmails = true
        selectedEmail = nil
        selectedEmailID = nil
        errorMessage = nil

        do {
            let fetchedEmails = try await client.fetchEmailPreviews(session: session, accountID: accountID, mailboxID: mailboxID)
            handleFetchedEmails(fetchedEmails, mailboxID: mailboxID)
            emails = fetchedEmails
            selectedEmailID = emails.first?.id

            if let selectedEmailID {
                await loadEmailDetail(emailID: selectedEmailID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingEmails = false
    }

    func loadEmailDetail(emailID: EmailPreview.ID) async {
        guard let client = makeClient(), let session, let accountID else {
            return
        }

        selectedEmailID = emailID
        isLoadingSelectedEmail = true
        errorMessage = nil

        do {
            selectedEmail = try await client.fetchEmailDetail(session: session, accountID: accountID, emailID: emailID)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingSelectedEmail = false
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
        let context = try await composeContext()

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

        await refreshIfViewing(mailboxRole: "drafts")
        return emailID
    }

    func send(_ draft: ComposeDraft) async throws {
        let context = try await composeContext()

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

    /// Compose can be triggered before the first refresh has landed, so this
    /// establishes the session on demand rather than failing.
    private func composeContext() async throws -> (client: JMAPClient, session: JMAPSession, accountID: String) {
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

    func startAutoFetch() {
        guard let session else {
            return
        }

        startAutoFetchIfNeeded(session: session)
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

    private func startAutoFetchIfNeeded(session: JMAPSession) {
        guard autoFetchTask == nil, let bearerToken else {
            return
        }

        Task {
            await notificationService.requestAuthorizationIfNeeded()
        }

        autoFetchTask = Task { [weak self] in
            guard let self else {
                return
            }

            if let eventSourceURL = session.eventSourceURL(types: ["Email"]) {
                await self.runEventSourceLoop(
                    eventSourceURL: eventSourceURL,
                    bearerToken: bearerToken
                )
            } else {
                await self.runFallbackRefreshLoop()
            }
        }
    }

    private func runEventSourceLoop(eventSourceURL: URL, bearerToken: String) async {
        while !Task.isCancelled {
            do {
                let eventSource = JMAPEventSource(url: eventSourceURL, bearerToken: bearerToken)
                for try await _ in eventSource.events() {
                    try Task.checkCancellation()
                    await refreshForAutoFetch()
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func runFallbackRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else {
                return
            }

            await refreshForAutoFetch()
        }
    }

    private func refreshForAutoFetch() async {
        guard let client = makeClient(), let session, let accountID else {
            await refresh()
            return
        }

        do {
            let mailboxes = try await client.fetchMailboxes(session: session, accountID: accountID)
            self.mailboxes = mailboxes

            guard let inboxID = mailboxes.first(where: { $0.role == "inbox" })?.id else {
                return
            }

            let inboxEmails = try await client.fetchEmailPreviews(session: session, accountID: accountID, mailboxID: inboxID)
            handleFetchedEmails(inboxEmails, mailboxID: inboxID)

            if selectedMailboxID == inboxID {
                let selectedEmailID = self.selectedEmailID
                emails = inboxEmails
                self.selectedEmailID = selectedEmailID ?? inboxEmails.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFetchedEmails(_ fetchedEmails: [EmailPreview], mailboxID: Mailbox.ID) {
        guard mailboxes.first(where: { $0.id == mailboxID })?.role == "inbox" else {
            return
        }

        let fetchedIDs = Set(fetchedEmails.map(\.id))
        defer {
            knownInboxEmailIDs = fetchedIDs
            hasLoadedInitialInboxSnapshot = true
        }

        guard hasLoadedInitialInboxSnapshot else {
            return
        }

        let newMessages = fetchedEmails.filter { email in
            !knownInboxEmailIDs.contains(email.id) && email.isUnread
        }

        guard !newMessages.isEmpty else {
            return
        }

        Task {
            await notificationService.notifyNewMessages(newMessages, mailboxName: "Inbox")
        }
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
                sortOrder: mailbox.sortOrder,
                totalEmails: mailbox.totalEmails,
                unreadEmails: adjustedUnread
            )
        }
    }

    private func loadSavedAccount() {
        if let data = UserDefaults.standard.data(forKey: accountStorageKey) {
            account = try? JSONDecoder().decode(MailAccount.self, from: data)
        }

        bearerToken = try? KeychainStore.loadToken()
    }
}

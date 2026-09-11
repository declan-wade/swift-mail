import Foundation

final class JMAPClient {
    private let sessionURL: URL
    private let bearerToken: String
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    init(sessionURL: URL, bearerToken: String, urlSession: URLSession = .shared) {
        self.sessionURL = sessionURL
        self.bearerToken = bearerToken
        self.urlSession = urlSession

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchSession() async throws -> JMAPSession {
        var request = URLRequest(url: sessionURL)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(JMAPSession.self, from: data)
    }

    func fetchMailboxes(session: JMAPSession, accountID: String) async throws -> [Mailbox] {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Mailbox/get",
                    [
                        "accountId": accountID,
                        "properties": ["id", "name", "role", "parentId", "sortOrder", "totalEmails", "unreadEmails"]
                    ],
                    "mailboxes"
                ]
            ]
        )

        let payload = try response.payload(named: "Mailbox/get", clientID: "mailboxes")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])
        let mailboxes = try decoder.decode([Mailbox].self, from: listData)

        return mailboxes.sorted { lhs, rhs in
            let lhsOrder = lhs.sortOrder ?? Int.max
            let rhsOrder = rhs.sortOrder ?? Int.max

            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }

            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// One page of a mailbox's message list.
    ///
    /// `Email/get` does not promise to return records in the order they were
    /// asked for, so the previews are re-sorted here to match the `Email/query`
    /// order — which matters once pages are stitched together on scroll.
    struct EmailPreviewPage {
        let previews: [EmailPreview]
        let position: Int
        let total: Int?
        /// The `Email` type state this page was fetched at, so an incremental
        /// sync can start from a known point rather than re-querying.
        let state: String?
        /// Thread id to every message in it, for the pages fetched with
        /// `collapseThreads`. Empty otherwise. This is what tells a collapsed
        /// row how many messages it stands for, and which to fetch when it is
        /// opened.
        let threadEmailIDs: [String: [String]]
    }

    /// The current server-side state string for each object type, used as the
    /// baseline for `Email/changes` / `Mailbox/get` incremental syncs.
    struct TypeStates {
        let email: String?
        let mailbox: String?
    }

    /// The result of `Email/changes` (RFC 8620 §5.2).
    struct EmailChanges {
        let oldState: String
        let newState: String
        let created: [String]
        let updated: [String]
        let destroyed: [String]
        let hasMoreChanges: Bool
    }

    /// Fetches just the `Email` and `Mailbox` type states — a near-empty request
    /// used by the polling fallback to detect whether anything changed before
    /// doing any real work.
    func fetchTypeStates(session: JMAPSession, accountID: String) async throws -> TypeStates {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                ["Email/get", ["accountId": accountID, "ids": [], "properties": ["id"]], "emailState"],
                ["Mailbox/get", ["accountId": accountID, "ids": [], "properties": ["id"]], "mailboxState"]
            ]
        )

        let emailPayload = try response.payload(named: "Email/get", clientID: "emailState")
        let mailboxPayload = try response.payload(named: "Mailbox/get", clientID: "mailboxState")

        return TypeStates(
            email: emailPayload["state"] as? String,
            mailbox: mailboxPayload["state"] as? String
        )
    }

    /// Asks the server which emails were created, updated or destroyed since
    /// `sinceState`. Throws `JMAPError.methodError("cannotCalculateChanges")`
    /// when the server can't answer incrementally and the caller must fall back
    /// to a full reload.
    func fetchEmailChanges(session: JMAPSession, accountID: String, sinceState: String) async throws -> EmailChanges {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/changes",
                    ["accountId": accountID, "sinceState": sinceState, "maxChanges": 200],
                    "changes"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/changes", clientID: "changes")

        return EmailChanges(
            oldState: payload["oldState"] as? String ?? sinceState,
            newState: payload["newState"] as? String ?? sinceState,
            created: payload["created"] as? [String] ?? [],
            updated: payload["updated"] as? [String] ?? [],
            destroyed: payload["destroyed"] as? [String] ?? [],
            hasMoreChanges: payload["hasMoreChanges"] as? Bool ?? false
        )
    }

    /// Fetches previews for a specific set of email ids — the incremental-sync
    /// counterpart to the paged `fetchEmailPreviews` above.
    func fetchEmailPreviews(session: JMAPSession, accountID: String, ids: [String]) async throws -> [EmailPreview] {
        guard !ids.isEmpty else {
            return []
        }

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/get",
                    ["accountId": accountID, "ids": ids, "properties": Self.previewProperties],
                    "emails"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/get", clientID: "emails")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])
        return try decoder.decode([EmailPreview].self, from: listData)
    }

    private static let previewProperties = [
        "id",
        "threadId",
        "mailboxIds",
        "from",
        "to",
        "cc",
        "subject",
        "receivedAt",
        "preview",
        "keywords",
        "hasAttachment",
        // Which of the account's addresses the message was delivered to, which
        // `to`/`cc` can't answer for anything that arrived via a relay.
        "header:X-Delivered-To:asAddresses"
    ]

    /// - Parameter collapseThreads: when true the query returns one message per
    ///   conversation — the newest that matches — and `Thread/get` comes back
    ///   in the same request with the full membership of each.
    /// - Parameter anchor: page from this message's place in the results
    ///   instead of from a numeric offset. An index moves whenever mail arrives
    ///   above it; an id doesn't. Throws `anchorNotFound` if the message is no
    ///   longer in the result set, which the caller answers by falling back to
    ///   `position`.
    /// - Parameter anchorOffset: added to the anchor's index. `1` means "the
    ///   page that starts just after this message".
    func fetchEmailPreviews(
        session: JMAPSession,
        accountID: String,
        mailboxID: String,
        position: Int = 0,
        anchor: String? = nil,
        anchorOffset: Int = 0,
        limit: Int = 50,
        searchFilter: [String: Any]? = nil,
        collapseThreads: Bool = false
    ) async throws -> EmailPreviewPage {
        let properties = Self.previewProperties
        let filter = searchFilter ?? ["inMailbox": mailboxID]

        var methodCalls: [[Any]] = [
            [
                "Email/query",
                Self.queryArguments(
                    accountID: accountID,
                    filter: filter,
                    position: position,
                    anchor: anchor,
                    anchorOffset: anchorOffset,
                    limit: limit,
                    collapseThreads: collapseThreads
                ),
                "query"
            ],
            [
                "Email/get",
                [
                    "accountId": accountID,
                    "#ids": [
                        "resultOf": "query",
                        "name": "Email/query",
                        "path": "/ids"
                    ],
                    "properties": properties
                ],
                "emails"
            ]
        ]

        if collapseThreads {
            // The thread ids aren't known until `Email/get` answers, so this
            // back-references its result rather than the query's: `/list/*/…`
            // is RFC 8620 3.7's wildcard for "that property of every item".
            methodCalls.append([
                "Thread/get",
                [
                    "accountId": accountID,
                    "#ids": [
                        "resultOf": "emails",
                        "name": "Email/get",
                        "path": "/list/*/threadId"
                    ]
                ],
                "threads"
            ])
        }

        let response = try await call(apiURL: session.apiURL, methodCalls: methodCalls)

        let queryPayload = try response.payload(named: "Email/query", clientID: "query")
        let orderedIDs = (queryPayload["ids"] as? [String]) ?? []
        let queryPosition = queryPayload["position"] as? Int ?? position
        let total = queryPayload["total"] as? Int

        let payload = try response.payload(named: "Email/get", clientID: "emails")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])
        let previews = try decoder.decode([EmailPreview].self, from: listData)

        let byID = Dictionary(previews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = orderedIDs.compactMap { byID[$0] }

        return EmailPreviewPage(
            previews: ordered.isEmpty ? previews : ordered,
            position: queryPosition,
            total: total,
            state: payload["state"] as? String,
            // `try?`: the counts are what let a row be opened, not what lets
            // the mailbox be read. A server that refuses `Thread/get` — or the
            // `/list/*/threadId` back-reference — degrades to a flat-looking
            // list rather than a folder that won't load at all.
            threadEmailIDs: collapseThreads
                ? (try? response.payload(named: "Thread/get", clientID: "threads"))
                    .map(Self.threadMembership) ?? [:]
                : [:]
        )
    }

    /// The `Email/query` arguments for one page.
    static func queryArguments(
        accountID: String,
        filter: [String: Any],
        position: Int,
        anchor: String?,
        anchorOffset: Int,
        limit: Int,
        collapseThreads: Bool
    ) -> [String: Any] {
        var arguments: [String: Any] = [
            "accountId": accountID,
            "filter": filter,
            "sort": [["property": "receivedAt", "isAscending": false]],
            "limit": limit,
            "calculateTotal": true,
            "collapseThreads": collapseThreads
        ]

        // RFC 8620 5.5: `position` is ignored when an anchor is given, so only
        // one of the two is ever sent rather than leaving a stale offset in the
        // request for a server to interpret.
        if let anchor {
            arguments["anchor"] = anchor
            arguments["anchorOffset"] = anchorOffset
        } else {
            arguments["position"] = position
        }

        return arguments
    }

    /// `Thread/get`'s list as a lookup from thread id to its messages.
    static func threadMembership(in payload: [String: Any]) -> [String: [String]] {
        guard let list = payload["list"] as? [[String: Any]] else {
            return [:]
        }

        return list.reduce(into: [:]) { result, thread in
            guard let id = thread["id"] as? String else {
                return
            }

            result[id] = thread["emailIds"] as? [String] ?? []
        }
    }

    /// Ids only, no `Email/get`. Sweep needs the whole matching set before it
    /// moves anything, and fetching previews for thousands of messages just to
    /// read their ids would be wasted traffic.
    func fetchEmailIDs(
        session: JMAPSession,
        accountID: String,
        searchFilter: [String: Any],
        position: Int,
        limit: Int
    ) async throws -> (ids: [String], total: Int?) {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/query",
                    [
                        "accountId": accountID,
                        "filter": searchFilter,
                        "sort": [["property": "receivedAt", "isAscending": false]],
                        "position": position,
                        "limit": limit,
                        "calculateTotal": true
                    ],
                    "query"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/query", clientID: "query")

        return ((payload["ids"] as? [String]) ?? [], payload["total"] as? Int)
    }

    /// Moves many messages in one `Email/set`. Replacing `mailboxIds` wholesale
    /// is what "move" means, and it's identical for every id, so the whole
    /// batch is one update object.
    ///
    /// Returns the ids the server refused, so the caller can report a partial
    /// result rather than claiming a clean sweep.
    func moveEmails(
        session: JMAPSession,
        accountID: String,
        emailIDs: [String],
        toMailboxID mailboxID: String
    ) async throws -> [String] {
        guard !emailIDs.isEmpty else {
            return []
        }

        // `uniquingKeysWith`, not `uniqueKeysWithValues`: a repeated id would
        // trap, and paging a live mailbox can hand us one.
        let update = Dictionary(
            emailIDs.map { ($0, ["mailboxIds": [mailboxID: true]]) },
            uniquingKeysWith: { first, _ in first }
        )

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/set",
                    [
                        "accountId": accountID,
                        "update": update
                    ],
                    "moveEmails"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/set", clientID: "moveEmails")

        return Array((payload["notUpdated"] as? [String: Any])?.keys ?? [:].keys)
    }

    /// Every message in one conversation, oldest first.
    ///
    /// `Thread/get` names the message ids and `Email/get` reads them in the same
    /// request via a back-reference, so a conversation costs one round trip
    /// rather than one per message.
    func fetchThreadEmails(session: JMAPSession, accountID: String, threadID: String) async throws -> [EmailPreview] {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                ["Thread/get", ["accountId": accountID, "ids": [threadID]], "thread"],
                [
                    "Email/get",
                    [
                        "accountId": accountID,
                        "#ids": [
                            "resultOf": "thread",
                            "name": "Thread/get",
                            "path": "/list/*/emailIds"
                        ],
                        "properties": Self.previewProperties
                    ],
                    "threadEmails"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/get", clientID: "threadEmails")
        let data = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])
        let emails = try decoder.decode([EmailPreview].self, from: data)

        return emails.sorted { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }
    }

    func fetchEmailDetail(session: JMAPSession, accountID: String, emailID: String) async throws -> EmailDetail {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/get",
                    [
                        "accountId": accountID,
                        "ids": [emailID],
                        "properties": [
                            "id",
                            "from",
                            "to",
                            "cc",
                            "bcc",
                            "replyTo",
                            "subject",
                            "receivedAt",
                            "sentAt",
                            "messageId",
                            "inReplyTo",
                            "references",
                            "preview",
                            "keywords",
                            "textBody",
                            "htmlBody",
                            "bodyValues",
                            "attachments"
                        ],
                        "fetchTextBodyValues": true,
                        "fetchHTMLBodyValues": true,
                        "maxBodyValueBytes": 200_000
                    ],
                    "email"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/get", clientID: "email")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])
        let emails = try decoder.decode([EmailDetail].self, from: listData)

        guard let email = emails.first else {
            throw JMAPError.emailNotFound
        }

        return email
    }

    func setEmailSeen(session: JMAPSession, accountID: String, emailID: String, isSeen: Bool) async throws {
        try await setEmailKeyword(session: session, accountID: accountID, emailID: emailID, keyword: "$seen", isSet: isSeen)
    }

    /// Sets or clears a single JMAP keyword (`$seen`, `$flagged`, …) on one
    /// email. A patch path lets the update touch only that keyword — an
    /// `Email/set` full `keywords` replacement would race any other client
    /// changing a different keyword at the same time.
    func setEmailKeyword(session: JMAPSession, accountID: String, emailID: String, keyword: String, isSet: Bool) async throws {
        let patchValue: Any = isSet ? true : NSNull()
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/set",
                    [
                        "accountId": accountID,
                        "update": [
                            emailID: [
                                "keywords/\(keyword)": patchValue
                            ]
                        ]
                    ],
                    "setEmailKeyword"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/set", clientID: "setEmailKeyword")
        if let notUpdated = payload["notUpdated"] as? [String: Any], !notUpdated.isEmpty {
            throw JMAPError.methodError("emailNotUpdated")
        }
    }

    /// Sets or clears one keyword across every message in a thread.
    ///
    /// `noneInThreadHaveKeyword` only needs one message to carry `$muted` for
    /// the whole thread to be excluded, but marking one and then deleting it
    /// would quietly unmute the thread — so every message gets it.
    func setThreadKeyword(
        session: JMAPSession,
        accountID: String,
        emailIDs: [String],
        keyword: String,
        isSet: Bool
    ) async throws {
        guard !emailIDs.isEmpty else {
            return
        }

        let patchValue: Any = isSet ? true : NSNull()
        let update = Dictionary(
            emailIDs.map { ($0, ["keywords/\(keyword)": patchValue]) },
            uniquingKeysWith: { first, _ in first }
        )

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                ["Email/set", ["accountId": accountID, "update": update], "setThreadKeyword"]
            ]
        )

        let payload = try response.payload(named: "Email/set", clientID: "setThreadKeyword")
        try Self.throwIfRejected(payload, key: "notUpdated")
    }

    /// Moves an email to a single destination mailbox, replacing its
    /// `mailboxIds` entirely. That matches how Mail treats archive/delete —
    /// the message leaves every mailbox it was filed under and lands in
    /// exactly one — rather than layering the destination on top.
    func moveEmail(session: JMAPSession, accountID: String, emailID: String, toMailboxID mailboxID: String) async throws {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/set",
                    [
                        "accountId": accountID,
                        "update": [
                            emailID: [
                                "mailboxIds": [mailboxID: true]
                            ]
                        ]
                    ],
                    "moveEmail"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/set", clientID: "moveEmail")
        if let notUpdated = payload["notUpdated"] as? [String: Any], !notUpdated.isEmpty {
            throw JMAPError.methodError("emailNotUpdated")
        }
    }

    /// Files a message into the Snoozed mailbox with a wake-up time.
    ///
    /// One `Email/set` does both, because the server only honours `snoozed` on
    /// a message in that mailbox, and moves it back out itself at `until` —
    /// whether or not this app is running. With no `moveToMailboxId` it goes
    /// to the Inbox, and it comes back unread so it resurfaces rather than
    /// slipping back in unnoticed.
    func snoozeEmail(
        session: JMAPSession,
        accountID: String,
        emailID: String,
        snoozedMailboxID: String,
        until: Date,
        using capabilities: [String]
    ) async throws {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/set",
                    [
                        "accountId": accountID,
                        "update": [
                            emailID: [
                                "mailboxIds": [snoozedMailboxID: true],
                                "snoozed": [
                                    "until": Self.utcDate(until),
                                    "setKeywords": ["$seen": false]
                                ]
                            ]
                        ]
                    ],
                    "snoozeEmail"
                ]
            ],
            using: capabilities
        )

        let payload = try response.payload(named: "Email/set", clientID: "snoozeEmail")
        try Self.throwIfRejected(payload, key: "notUpdated")
    }

    /// Everything in the Snoozed mailbox with its wake-up time, soonest first.
    ///
    /// Sorted here rather than by the query: the draft defines no sort on the
    /// wake-up time, and Cyrus's `snoozedUntil` is its own extension.
    // ponytail: first 100 only; page it if anyone snoozes more than that.
    func fetchSnoozedEmails(
        session: JMAPSession,
        accountID: String,
        mailboxID: String,
        using capabilities: [String]
    ) async throws -> [SnoozedEmail] {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/query",
                    ["accountId": accountID, "filter": ["inMailbox": mailboxID], "limit": 100],
                    "snoozedQuery"
                ],
                [
                    "Email/get",
                    [
                        "accountId": accountID,
                        "#ids": ["resultOf": "snoozedQuery", "name": "Email/query", "path": "/ids"],
                        "properties": ["id", "subject", "from", "snoozed"]
                    ],
                    "snoozedEmails"
                ]
            ],
            using: capabilities
        )

        let payload = try response.payload(named: "Email/get", clientID: "snoozedEmails")
        let data = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])

        return try decoder.decode([SnoozedEmail].self, from: data).sorted(by: SnoozedEmail.soonestFirst)
    }

    /// What the server returns from the upload endpoint (RFC 8620 6.1).
    nonisolated struct UploadedBlob: Decodable {
        let blobId: String
        let type: String?
        let size: Int?
    }

    /// Uploads one file and returns its blob. A blob is referenced by id when
    /// the message is created, so this happens once per file rather than being
    /// re-sent for every draft save.
    func uploadBlob(session: JMAPSession, accountID: String, data: Data, type: String) async throws -> UploadedBlob {
        guard let url = session.uploadURL(accountID: accountID) else {
            throw JMAPError.missingUploadURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (responseData, response) = try await urlSession.upload(for: request, from: data)
        try validate(response: response, data: responseData)

        return try decoder.decode(UploadedBlob.self, from: responseData)
    }

    // MARK: - Compose

    func fetchIdentities(session: JMAPSession, accountID: String) async throws -> [MailIdentity] {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Identity/get",
                    ["accountId": accountID],
                    "identities"
                ]
            ],
            using: JMAPCapability.submission
        )

        let payload = try response.payload(named: "Identity/get", clientID: "identities")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])
        return try decoder.decode([MailIdentity].self, from: listData)
    }

    /// Fetches one attachment's bytes from the session's `downloadUrl`.
    func downloadBlob(session: JMAPSession, accountID: String, attachment: EmailAttachment) async throws -> Data {
        guard let blobID = attachment.blobId,
              let url = session.downloadURL(
                  accountID: accountID,
                  blobID: blobID,
                  type: attachment.type,
                  name: attachment.displayName
              ) else {
            throw JMAPError.missingDownloadURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)

        return data
    }

    /// Creates the draft in the Drafts mailbox and returns its new email ID.
    @discardableResult
    func createDraft(
        session: JMAPSession,
        accountID: String,
        draft: ComposeDraft,
        identity: MailIdentity,
        draftsMailboxID: String
    ) async throws -> String {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/set",
                    [
                        "accountId": accountID,
                        "create": [
                            Self.draftCreationID: Self.emailObject(
                                draft: draft,
                                identity: identity,
                                mailboxIDs: [draftsMailboxID: true],
                                keywords: ["$draft": true, "$seen": true]
                            )
                        ]
                    ],
                    "createDraft"
                ]
            ]
        )

        let payload = try response.payload(named: "Email/set", clientID: "createDraft")
        try Self.throwIfRejected(payload, key: "notCreated")

        guard let created = payload["created"] as? [String: Any],
              let record = created[Self.draftCreationID] as? [String: Any],
              let emailID = record["id"] as? String else {
            throw JMAPError.invalidResponse
        }

        return emailID
    }

    /// Permanently removes a draft the user resumed editing, so a resumed draft
    /// that is re-saved or sent doesn't leave its earlier version behind in the
    /// Drafts mailbox. A no-op `notDestroyed` entry is tolerated — the draft may
    /// already be gone.
    func destroyEmail(session: JMAPSession, accountID: String, emailID: String) async throws {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/set",
                    [
                        "accountId": accountID,
                        "destroy": [emailID]
                    ],
                    "destroyEmail"
                ]
            ]
        )

        _ = try response.payload(named: "Email/set", clientID: "destroyEmail")
    }

    /// Creates the message and hands it to the submission queue in one request.
    ///
    /// `onSuccessUpdateEmail` is what moves the message out of Drafts and into
    /// Sent, so the transition only happens if the submission itself succeeded.
    ///
    /// - Parameter sendAt: when the server should release the message. A future
    ///   date makes the submission cancellable until then — which is both
    ///   "send later" and, at a few seconds out, "undo send". Servers cap this
    ///   at `maxDelayedSend`; the caller clamps.
    /// - Returns: the submission's id, the handle a later cancel needs. Nil if
    ///   the server answered without one — the mail still went, so that is not
    ///   an error, only an undo the app can't offer.
    @discardableResult
    func send(
        session: JMAPSession,
        accountID: String,
        submissionAccountID: String,
        draft: ComposeDraft,
        identity: MailIdentity,
        draftsMailboxID: String,
        fileInMailboxID: String?,
        sendAt: Date? = nil
    ) async throws -> String? {
        var emailArguments: [String: Any] = [
            "accountId": accountID,
            "create": [
                Self.draftCreationID: Self.emailObject(
                    draft: draft,
                    identity: identity,
                    mailboxIDs: [draftsMailboxID: true],
                    keywords: ["$draft": true, "$seen": true]
                )
            ]
        ]

        // Flag the message being answered in the same round trip.
        if let originalEmailID = draft.originalEmailID, let keyword = draft.mode.originalKeyword {
            emailArguments["update"] = [originalEmailID: ["keywords/\(keyword)": true]]
        }

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                ["Email/set", emailArguments, "createDraft"],
                [
                    "EmailSubmission/set",
                    Self.submitArguments(
                        accountID: submissionAccountID,
                        draft: draft,
                        identity: identity,
                        draftsMailboxID: draftsMailboxID,
                        fileInMailboxID: fileInMailboxID,
                        sendAt: sendAt
                    ),
                    "submit"
                ]
            ],
            using: JMAPCapability.submission
        )

        let emailPayload = try response.payload(named: "Email/set", clientID: "createDraft")
        try Self.throwIfRejected(emailPayload, key: "notCreated")

        let submissionPayload = try response.payload(named: "EmailSubmission/set", clientID: "submit")
        try Self.throwIfRejected(submissionPayload, key: "notCreated")

        return Self.createdID(in: submissionPayload, creationID: Self.submissionCreationID)
    }

    /// The `EmailSubmission/set` half of a send, back-referencing the `Email`
    /// created alongside it.
    ///
    /// - Parameter fileInMailboxID: where the message goes once the submission
    ///   is accepted — Sent for an immediate send, Scheduled for one the server
    ///   is holding. The caller chooses, because only it knows which mailboxes
    ///   this account actually has.
    static func submitArguments(
        accountID: String,
        draft: ComposeDraft,
        identity: MailIdentity,
        draftsMailboxID: String,
        fileInMailboxID: String?,
        sendAt: Date?
    ) -> [String: Any] {
        var onSuccess: [String: Any] = ["keywords/$draft": NSNull()]
        if let fileInMailboxID {
            onSuccess["mailboxIds/\(fileInMailboxID)"] = true
            onSuccess["mailboxIds/\(draftsMailboxID)"] = NSNull()
        }

        var submission: [String: Any] = [
            "emailId": "#\(draftCreationID)",
            "identityId": identity.id,
            "envelope": [
                "mailFrom": ["email": identity.email],
                "rcptTo": draft.allRecipients.map { ["email": $0.email] }
            ]
        ]

        // Omitted rather than sent as null for an immediate send: RFC 8621 7.1
        // defaults `sendAt` to "now", and a server that caps `maxDelayedSend`
        // at 0 rejects the property outright.
        if let sendAt {
            submission["sendAt"] = utcDate(sendAt)
        }

        return [
            "accountId": accountID,
            "create": [submissionCreationID: submission],
            "onSuccessUpdateEmail": ["#\(submissionCreationID)": onSuccess]
        ]
    }

    /// Cancels a submission the server is still holding and puts the message
    /// back in Drafts, editable, as if it had never been sent.
    ///
    /// The revert rides on `onSuccessUpdateEmail` rather than a second method
    /// call: JMAP runs every call in a request whatever the one before it did,
    /// so a separate `Email/set` would drag a message back out of Sent even
    /// when the cancel had failed and the mail was already gone.
    func cancelSubmission(
        session: JMAPSession,
        submissionAccountID: String,
        submissionID: String,
        draftsMailboxID: String,
        fileInMailboxID: String?
    ) async throws {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "EmailSubmission/set",
                    Self.cancelArguments(
                        accountID: submissionAccountID,
                        submissionID: submissionID,
                        draftsMailboxID: draftsMailboxID,
                        fileInMailboxID: fileInMailboxID
                    ),
                    "cancel"
                ]
            ],
            using: JMAPCapability.submission
        )

        let payload = try response.payload(named: "EmailSubmission/set", clientID: "cancel")
        try Self.throwIfRejected(payload, key: "notUpdated")
    }

    /// - Parameter fileInMailboxID: the mailbox the send filed it into, which
    ///   it has to leave on the way back to Drafts.
    static func cancelArguments(
        accountID: String,
        submissionID: String,
        draftsMailboxID: String,
        fileInMailboxID: String?
    ) -> [String: Any] {
        // The exact inverse of the send's `onSuccessUpdateEmail`.
        var revert: [String: Any] = [
            "keywords/$draft": true,
            "mailboxIds/\(draftsMailboxID)": true
        ]
        if let fileInMailboxID {
            revert["mailboxIds/\(fileInMailboxID)"] = NSNull()
        }

        return [
            "accountId": accountID,
            "update": [submissionID: ["undoStatus": "canceled"]],
            "onSuccessUpdateEmail": [submissionID: revert]
        ]
    }

    private static func createdID(in payload: [String: Any], creationID: String) -> String? {
        ((payload["created"] as? [String: Any])?[creationID] as? [String: Any])?["id"] as? String
    }

    /// RFC 8620 1.4 `UTCDate`: seconds precision, always `Z`.
    static func utcDate(_ date: Date) -> String {
        utcDateFormatter.string(from: date)
    }

    private static let utcDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let draftCreationID = "draft"
    private static let submissionCreationID = "submission"

    /// Builds the `Email` object for `Email/set`.
    ///
    /// The body is always `multipart/alternative`: the Markdown source ships as
    /// the text part, so recipients on plain-text clients read what the author
    /// actually typed rather than a lossy downgrade of the rendered HTML.
    ///
    /// The body parts carry no `charset`: RFC 8621 4.6 says it MUST be omitted
    /// when a `partId` is given, and Fastmail enforces that with
    /// `invalidProperties`, which rejected every send.
    /// The alternative text/html pair, wrapped in a `multipart/mixed` alongside
    /// the attachment parts when there are any. Staying with `bodyStructure`
    /// rather than switching to the `textBody`/`htmlBody`/`attachments`
    /// convenience form keeps one convention: RFC 8621 4.1.4 allows either, but
    /// not both in the same create.
    private static func bodyStructure(for draft: ComposeDraft) -> [String: Any] {
        let alternative: [String: Any] = [
            "type": "multipart/alternative",
            "subParts": [
                ["partId": "text", "type": "text/plain"],
                ["partId": "html", "type": "text/html"]
            ]
        ]

        // Inline parts belong *inside* a `multipart/related` with the body that
        // references them, not beside it in the mixed part — that relationship
        // is what lets a recipient's client resolve `cid:` back to the image.
        let inline = draft.attachments.filter(\.isInline)
        let body: [String: Any] = inline.isEmpty ? alternative : [
            "type": "multipart/related",
            "subParts": [alternative] + inline.map { attachment in
                var part = part(for: attachment, disposition: "inline")
                part["cid"] = attachment.contentID
                return part
            }
        ]

        let files = draft.listedAttachments
        guard !files.isEmpty else {
            return body
        }

        return [
            "type": "multipart/mixed",
            "subParts": [body] + files.map { part(for: $0, disposition: "attachment") }
        ]
    }

    /// The user's Markdown, rendered, with the forwarded message's own HTML
    /// appended untouched when this is an HTML forward.
    private static func htmlBody(for draft: ComposeDraft) -> String {
        let authored = MarkdownRenderer.htmlDocument(from: draft.markdown)

        guard let forwarded = draft.forwardedHTML else {
            return authored
        }

        return authored + forwarded
    }

    /// The plain-text alternative. A preserved HTML forward has no faithful
    /// text equivalent, so the original is flattened for it rather than
    /// shipping a text part that silently omits the forwarded message.
    private static func plainTextBody(for draft: ComposeDraft) -> String {
        let authored = MarkdownRenderer.plainText(from: draft.markdown)

        guard let forwarded = draft.forwardedHTML else {
            return authored
        }

        return authored + "\n\n" + forwarded.htmlStripped()
    }

    private static func part(for attachment: ComposeAttachment, disposition: String) -> [String: Any] {
        [
            "blobId": attachment.blobId,
            "type": attachment.type,
            "name": attachment.name,
            "disposition": disposition
        ]
    }

    static func emailObject(
        draft: ComposeDraft,
        identity: MailIdentity,
        mailboxIDs: [String: Bool],
        keywords: [String: Bool]
    ) -> [String: Any] {
        var email: [String: Any] = [
            "mailboxIds": mailboxIDs,
            "keywords": keywords,
            "from": addressList([identity.address]),
            "subject": draft.subject,
            "bodyStructure": bodyStructure(for: draft),
            "bodyValues": [
                "text": ["value": plainTextBody(for: draft)],
                "html": ["value": htmlBody(for: draft)]
            ]
        ]

        if !draft.to.isEmpty {
            email["to"] = addressList(draft.to)
        }
        if !draft.cc.isEmpty {
            email["cc"] = addressList(draft.cc)
        }
        if !draft.bcc.isEmpty {
            email["bcc"] = addressList(draft.bcc)
        }
        if let replyTo = identity.replyTo, !replyTo.isEmpty {
            email["replyTo"] = addressList(replyTo)
        }
        if !draft.inReplyTo.isEmpty {
            email["inReplyTo"] = draft.inReplyTo
        }
        if !draft.references.isEmpty {
            email["references"] = draft.references
        }

        return email
    }

    private static func addressList(_ addresses: [EmailAddress]) -> [[String: Any]] {
        addresses.map { address in
            var entry: [String: Any] = ["email": address.email]
            if let name = address.name, !name.isEmpty {
                entry["name"] = name
            }

            return entry
        }
    }

    /// `Email/set` and `EmailSubmission/set` report per-record failures in the
    /// response body rather than as method errors, so they need their own check.
    private static func throwIfRejected(_ payload: [String: Any], key: String) throws {
        guard let rejected = payload[key] as? [String: Any], !rejected.isEmpty else {
            return
        }

        let detail = rejected.values
            .compactMap { ($0 as? [String: Any])?["description"] as? String }
            .first
            ?? rejected.values
                .compactMap { ($0 as? [String: Any])?["properties"] as? [String] }
                .first
                .map { $0.joined(separator: ", ") }

        let type = rejected.values
            .compactMap { ($0 as? [String: Any])?["type"] as? String }
            .first

        throw JMAPError.setError(type ?? "unknown", detail)
    }

    // MARK: - Masked Email

    /// Every masked address on the account, including deleted ones — the UI
    /// filters those out, but recovering one means being able to see it.
    func fetchMaskedEmails(session: JMAPSession, accountID: String) async throws -> [MaskedEmail] {
        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                ["MaskedEmail/get", ["accountId": accountID, "ids": NSNull()], "maskedEmails"]
            ],
            using: JMAPCapability.maskedEmail
        )

        let payload = try response.payload(named: "MaskedEmail/get", clientID: "maskedEmails")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])

        return try decoder.decode([MaskedEmail].self, from: listData)
    }

    /// Creates one address and reads it back in the same request.
    ///
    /// A `/set` response carries only the properties the server chose, so the
    /// created id is fed straight into a `/get` by back-reference rather than
    /// stitching a half-server, half-local object together here.
    func createMaskedEmail(
        session: JMAPSession,
        accountID: String,
        forDomain: String?,
        note: String?,
        prefix: String?
    ) async throws -> MaskedEmail {
        var create: [String: Any] = ["state": MaskedEmailState.enabled.rawValue]

        // Sent only when they hold something: Fastmail treats an empty prefix
        // as a request for an empty prefix rather than as "you choose".
        if let forDomain = forDomain?.nilIfEmpty {
            create["forDomain"] = forDomain
        }

        if let note = note?.nilIfEmpty {
            create["description"] = note
        }

        if let prefix = prefix?.nilIfEmpty {
            create["emailPrefix"] = prefix
        }

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "MaskedEmail/set",
                    ["accountId": accountID, "create": ["new": create]],
                    "createMaskedEmail"
                ],
                [
                    "MaskedEmail/get",
                    [
                        "accountId": accountID,
                        "#ids": [
                            "resultOf": "createMaskedEmail",
                            "name": "MaskedEmail/set",
                            "path": "/created/new/id"
                        ]
                    ],
                    "createdMaskedEmail"
                ]
            ],
            using: JMAPCapability.maskedEmail
        )

        let setPayload = try response.payload(named: "MaskedEmail/set", clientID: "createMaskedEmail")
        try Self.throwIfRejected(setPayload, key: "notCreated")

        let payload = try response.payload(named: "MaskedEmail/get", clientID: "createdMaskedEmail")
        let listData = try JSONSerialization.data(withJSONObject: payload["list"] ?? [])

        guard let created = try decoder.decode([MaskedEmail].self, from: listData).first else {
            throw JMAPError.invalidResponse
        }

        return created
    }

    /// Patches one address. Only the named properties are sent, so two clients
    /// changing different fields don't overwrite each other.
    func updateMaskedEmail(
        session: JMAPSession,
        accountID: String,
        id: String,
        state: MaskedEmailState? = nil,
        note: String? = nil
    ) async throws {
        var patch: [String: Any] = [:]

        if let state {
            patch["state"] = state.rawValue
        }

        if let note {
            patch["description"] = note
        }

        guard !patch.isEmpty else {
            return
        }

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "MaskedEmail/set",
                    ["accountId": accountID, "update": [id: patch]],
                    "updateMaskedEmail"
                ]
            ],
            using: JMAPCapability.maskedEmail
        )

        let payload = try response.payload(named: "MaskedEmail/set", clientID: "updateMaskedEmail")
        try Self.throwIfRejected(payload, key: "notUpdated")
    }

    private func call(
        apiURL: URL,
        methodCalls: [[Any]],
        using capabilities: [String] = JMAPCapability.mail
    ) async throws -> JMAPInvocationResponse {
        let body: [String: Any] = [
            "using": capabilities,
            "methodCalls": methodCalls
        ]

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw JMAPError.invalidResponse
        }

        return JMAPInvocationResponse(dictionary: dictionary)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JMAPError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw JMAPError.httpStatus(httpResponse.statusCode, message)
        }
    }
}

struct JMAPInvocationResponse {
    let dictionary: [String: Any]

    func payload(named methodName: String, clientID: String) throws -> [String: Any] {
        guard let responses = dictionary["methodResponses"] as? [[Any]] else {
            throw JMAPError.invalidResponse
        }

        for response in responses {
            guard response.count == 3,
                  let name = response[0] as? String,
                  let arguments = response[1] as? [String: Any],
                  let id = response[2] as? String else {
                continue
            }

            if name == "error" {
                throw JMAPError.methodError(arguments["type"] as? String ?? "unknown")
            }

            if name == methodName && id == clientID {
                return arguments
            }
        }

        throw JMAPError.missingMethodResponse(methodName)
    }
}

nonisolated enum JMAPCapability {
    static let core = "urn:ietf:params:jmap:core"
    static let mailURN = "urn:ietf:params:jmap:mail"
    static let submissionURN = "urn:ietf:params:jmap:submission"
    /// draft-ietf-extra-email-snooze, expired and undocumented by Fastmail —
    /// checked at runtime rather than assumed.
    static let snoozeURN = "urn:ietf:params:jmap:mail:snooze"
    /// Cyrus's own mail extension, which is where Fastmail's server (Cyrus)
    /// keeps `snoozed` when the draft's URN isn't advertised.
    static let cyrusMailURN = "https://cyrusimap.org/ns/jmap/mail"

    /// Fastmail's Masked Email extension. Vendor-specific and gated on the API
    /// token's own scope, so a token without it simply doesn't advertise the
    /// capability — which is the check the UI keys off.
    static let maskedEmailURN = "https://www.fastmail.com/dev/maskedemail"

    static let mail = [core, mailURN]
    static let maskedEmail = [core, maskedEmailURN]
    /// Submission requests still touch `Email` objects, so mail comes along.
    static let submission = [core, mailURN, submissionURN]
}

enum JMAPError: LocalizedError {
    case emailNotFound
    case httpStatus(Int, String?)
    case invalidEventSourceResponse
    case invalidResponse
    case methodError(String)
    case missingIdentity
    case missingMailAccount
    case missingDownloadURL
    case missingUploadURL
    case attachmentTooLarge(String, Int)
    case missingMailbox(String)
    case missingMethodResponse(String)
    case setError(String, String?)

    var errorDescription: String? {
        switch self {
        case .emailNotFound:
            return "The selected email could not be found."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "The JMAP server returned HTTP \(status): \(message)"
            }

            return "The JMAP server returned HTTP \(status)."
        case .invalidEventSourceResponse:
            return "The JMAP event source returned a response this app could not read."
        case .invalidResponse:
            return "The JMAP server returned a response this app could not read."
        case .methodError(let type):
            return "The JMAP server returned a method error: \(type)."
        case .missingIdentity:
            return "No sending identity is available for this account."
        case .missingMailAccount:
            return "The JMAP session does not expose a mail account."
        case .missingDownloadURL:
            return "This attachment has no downloadable content."
        case .missingUploadURL:
            return "This account does not advertise an upload endpoint, so files can't be attached."
        case .attachmentTooLarge(let name, let limit):
            return "\(name) is larger than the \(Int64(limit).formatted(.byteCount(style: .file))) this server accepts."
        case .missingMailbox(let role):
            return "This account has no \(role) mailbox, so the message could not be filed."
        case .missingMethodResponse(let method):
            return "The JMAP response did not include \(method)."
        case .setError(let type, let detail):
            if let detail, !detail.isEmpty {
                return "The server rejected the message (\(type)): \(detail)"
            }

            return "The server rejected the message (\(type))."
        }
    }
}

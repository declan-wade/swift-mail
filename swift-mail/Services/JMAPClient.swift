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
        "subject",
        "receivedAt",
        "preview",
        "keywords",
        "hasAttachment"
    ]

    func fetchEmailPreviews(
        session: JMAPSession,
        accountID: String,
        mailboxID: String,
        position: Int = 0,
        limit: Int = 50,
        searchFilter: [String: Any]? = nil
    ) async throws -> EmailPreviewPage {
        let properties = Self.previewProperties
        let filter = searchFilter ?? ["inMailbox": mailboxID]

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                [
                    "Email/query",
                    [
                        "accountId": accountID,
                        "filter": filter,
                        "sort": [["property": "receivedAt", "isAscending": false]],
                        "position": position,
                        "limit": limit,
                        "calculateTotal": true
                    ],
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
        )

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
            state: payload["state"] as? String
        )
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
    func send(
        session: JMAPSession,
        accountID: String,
        submissionAccountID: String,
        draft: ComposeDraft,
        identity: MailIdentity,
        draftsMailboxID: String,
        sentMailboxID: String?
    ) async throws {
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

        var onSuccess: [String: Any] = ["keywords/$draft": NSNull()]
        if let sentMailboxID {
            onSuccess["mailboxIds/\(sentMailboxID)"] = true
            onSuccess["mailboxIds/\(draftsMailboxID)"] = NSNull()
        }

        let submissionArguments: [String: Any] = [
            "accountId": submissionAccountID,
            "create": [
                Self.submissionCreationID: [
                    "emailId": "#\(Self.draftCreationID)",
                    "identityId": identity.id,
                    "envelope": [
                        "mailFrom": ["email": identity.email],
                        "rcptTo": draft.allRecipients.map { ["email": $0.email] }
                    ]
                ]
            ],
            "onSuccessUpdateEmail": ["#\(Self.submissionCreationID)": onSuccess]
        ]

        let response = try await call(
            apiURL: session.apiURL,
            methodCalls: [
                ["Email/set", emailArguments, "createDraft"],
                ["EmailSubmission/set", submissionArguments, "submit"]
            ],
            using: JMAPCapability.submission
        )

        let emailPayload = try response.payload(named: "Email/set", clientID: "createDraft")
        try Self.throwIfRejected(emailPayload, key: "notCreated")

        let submissionPayload = try response.payload(named: "EmailSubmission/set", clientID: "submit")
        try Self.throwIfRejected(submissionPayload, key: "notCreated")
    }

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
            "bodyStructure": [
                "type": "multipart/alternative",
                "subParts": [
                    ["partId": "text", "type": "text/plain"],
                    ["partId": "html", "type": "text/html"]
                ]
            ],
            "bodyValues": [
                "text": ["value": MarkdownRenderer.plainText(from: draft.markdown)],
                "html": ["value": MarkdownRenderer.htmlDocument(from: draft.markdown)]
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

    static let mail = [core, mailURN]
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

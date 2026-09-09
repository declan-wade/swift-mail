import Foundation
import CryptoKit
import SQLite3

/// SQLite wants to know whether a bound string outlives the call. It never does
/// here, so every bind is copied.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One change the user made that the server has not accepted yet.
///
/// The point of writing these down is that a flag or an archive stops depending
/// on the network being up at the moment it is tapped: the change lands on
/// screen immediately, and the send is a separate obligation the app owes the
/// server until it drains — across a relaunch if need be.
nonisolated struct OutboxEntry: Identifiable, Hashable, Codable {
    /// What to do. Deliberately a closed set: an outbox that can hold arbitrary
    /// work is a job queue, and this only ever needs the two mutations the UI
    /// actually offers.
    enum Action: Hashable, Codable {
        case keyword(String, isSet: Bool)
        case move(mailboxID: String)
    }

    var id: UUID
    var emailID: String
    var action: Action
    /// How many times the *server* has refused this. Never incremented while
    /// offline, so it counts rejections rather than lost connectivity.
    var attempts: Int
    var queuedAt: Date

    init(id: UUID = UUID(), emailID: String, action: Action, attempts: Int = 0, queuedAt: Date = Date()) {
        self.id = id
        self.emailID = emailID
        self.action = action
        self.attempts = attempts
        self.queuedAt = queuedAt
    }

    /// Identifies changes that supersede one another. Toggling read three times
    /// should send one update, not three, and only the last move matters.
    var coalescingKey: String {
        switch action {
        case .keyword(let keyword, _): "keyword:\(keyword)"
        case .move: "move"
        }
    }

    /// The same change laid back over a preview the server just sent us.
    func apply(to preview: EmailPreview) -> EmailPreview {
        switch action {
        case .keyword("$seen", let isSet): preview.settingSeen(isSet)
        case .keyword("$flagged", let isSet): preview.settingFlagged(isSet)
        case .keyword: preview
        case .move(let mailboxID): preview.settingMailbox(mailboxID)
        }
    }
}

/// The on-disk mirror of one account: what the server said last time, so a
/// launch has mail before the network answers and a folder switch doesn't drop
/// back to a skeleton.
///
/// Three things make this simpler than a general-purpose store, and all three
/// come from JMAP rather than from us:
///
/// - An `Email` is immutable except for `keywords` and `mailboxIds` (RFC 8621
///   §4.1), so a cached body is correct forever and never needs revalidating.
/// - The sync path refetches *whole* previews for changed ids, so a row is
///   always replaced and never patched. That is why messages live in one table
///   instead of being split by mutability — the split would buy a join and a
///   merge-init for a write pattern that never happens here.
/// - Everything is recoverable from the server, so there is no migration path:
///   a schema bump or a different account drops the file and re-syncs.
///
/// Opened in SQLite's serialized mode, so the library does its own locking and
/// this type needs no mutex. Reads are synchronous because they are small and
/// because `MailStore.init()` has nothing to await from; the one genuinely
/// large write, an attachment blob, is dispatched off the main actor by its
/// caller.
final class MailCache: @unchecked Sendable {
    static let shared = MailCache()

    /// Bump on any change an older file can't satisfy. The old file is dropped.
    private static let schemaVersion = 2

    /// Message bodies are the only unbounded table. Evicted oldest-first once
    /// the total passes this.
    private static let bodyByteBudget = 32 * 1024 * 1024
    /// Attachment bytes on disk, evicted oldest-first past this.
    private static let blobByteBudget = 200 * 1024 * 1024

    private var db: OpaquePointer?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    // MARK: - Lifecycle

    private static var directory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        let directory = support.appending(path: "SwiftMail", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory
    }

    private var blobDirectory: URL? {
        guard let base = blobBase else {
            return nil
        }

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        return base
    }

    /// Set alongside the database so a test can point both at a scratch folder.
    private var blobBase: URL?
    /// The file currently open, so re-opening the same one is a no-op and a
    /// different one replaces the connection instead of being ignored.
    private var openFile: URL?

    /// Opens the cache for one account, discarding anything that belonged to a
    /// different account or an older schema. Safe to call more than once.
    ///
    /// `url` is for tests; production passes nil and gets Application Support.
    func open(accountKey: String, at url: URL? = nil) {
        guard let file = url ?? Self.directory?.appending(path: "cache.sqlite") else {
            return
        }

        if db != nil {
            guard file != openFile else {
                return
            }

            // Pointing at a different database has to close the old one, or the
            // connection and the blob directory drift apart.
            sqlite3_close(db)
            db = nil
        }

        openFile = file
        blobBase = file.deletingLastPathComponent().appending(path: "Blobs", directoryHint: .isDirectory)

        // Serialized mode: SQLite guards the connection itself, so callers on
        // different actors need no coordination here.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(file.path, &db, flags, nil) == SQLITE_OK else {
            db = nil
            return
        }

        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")
        createTables()

        // A cache is disposable by definition: rather than migrate it, throw it
        // away and let the next sync refill it.
        let storedVersion = Int(meta("schema_version") ?? "") ?? 0
        if storedVersion != Self.schemaVersion || meta("account_key") != accountKey {
            dropEverything()
            createTables()
            setMeta("schema_version", String(Self.schemaVersion))
            setMeta("account_key", accountKey)
        }
    }

    private func createTables() {
        execute("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

        CREATE TABLE IF NOT EXISTS sync_state (type TEXT PRIMARY KEY, state TEXT);

        CREATE TABLE IF NOT EXISTS mailbox (id TEXT PRIMARY KEY, position INTEGER, json TEXT);

        CREATE TABLE IF NOT EXISTS identity (id TEXT PRIMARY KEY, position INTEGER, json TEXT);

        CREATE TABLE IF NOT EXISTS email (
            id TEXT PRIMARY KEY,
            thread_id TEXT,
            received_at REAL,
            json TEXT);

        CREATE TABLE IF NOT EXISTS email_mailbox (
            email_id TEXT,
            mailbox_id TEXT,
            PRIMARY KEY (email_id, mailbox_id));

        CREATE TABLE IF NOT EXISTS email_body (
            id TEXT PRIMARY KEY,
            json TEXT,
            bytes INTEGER,
            touched_at REAL);

        CREATE TABLE IF NOT EXISTS outbox (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT UNIQUE,
            email_id TEXT,
            action_key TEXT,
            action TEXT,
            attempts INTEGER,
            queued_at REAL);

        CREATE INDEX IF NOT EXISTS email_by_time ON email (received_at DESC);
        CREATE INDEX IF NOT EXISTS outbox_by_email ON outbox (email_id);
        CREATE INDEX IF NOT EXISTS email_mailbox_lookup ON email_mailbox (mailbox_id);
        CREATE INDEX IF NOT EXISTS body_by_age ON email_body (touched_at);
        """)
    }

    private func dropEverything() {
        execute("""
        DROP TABLE IF EXISTS meta;
        DROP TABLE IF EXISTS sync_state;
        DROP TABLE IF EXISTS mailbox;
        DROP TABLE IF EXISTS identity;
        DROP TABLE IF EXISTS email;
        DROP TABLE IF EXISTS email_mailbox;
        DROP TABLE IF EXISTS email_body;
        DROP TABLE IF EXISTS outbox;
        """)

        if let base = blobBase {
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// Signing out: everything cached belonged to that account, and nobody owns
    /// the file now. The schema stamp stays, because it describes the file's
    /// shape rather than its contents — dropping it would make the next `open`
    /// read an empty cache as an incompatible one and discard it a second time.
    func clear() {
        dropEverything()
        createTables()
        setMeta("schema_version", String(Self.schemaVersion))
    }

    /// Hands the file to a different account: empty, and stamped with its new
    /// owner so the next launch recognises it instead of dropping it.
    func reset(accountKey: String) {
        clear()
        setMeta("account_key", accountKey)
    }

    // MARK: - Sync cursors

    /// The stored `state` for a JMAP type. Restoring this is what lets the first
    /// sync of a launch ask for a delta rather than re-query the mailbox.
    func syncState(for type: String) -> String? {
        query("SELECT state FROM sync_state WHERE type = ?;", bind: [type]) { $0.text(0) }.first
    }

    func setSyncState(_ state: String?, for type: String) {
        guard let state else {
            return
        }

        run("INSERT OR REPLACE INTO sync_state (type, state) VALUES (?, ?);", bind: [type, state])
    }

    // MARK: - Folders and identities

    func mailboxes() -> [Mailbox] {
        query("SELECT json FROM mailbox ORDER BY position;", bind: []) { $0.text(0) }
            .compactMap { decode(Mailbox.self, from: $0) }
    }

    func setMailboxes(_ mailboxes: [Mailbox]) {
        transaction {
            run("DELETE FROM mailbox;", bind: [])

            for (index, mailbox) in mailboxes.enumerated() {
                guard let json = encode(mailbox) else { continue }

                run("INSERT INTO mailbox (id, position, json) VALUES (?, ?, ?);",
                    bind: [mailbox.id, index, json])
            }
        }
    }

    func identities() -> [MailIdentity] {
        query("SELECT json FROM identity ORDER BY position;", bind: []) { $0.text(0) }
            .compactMap { decode(MailIdentity.self, from: $0) }
    }

    func setIdentities(_ identities: [MailIdentity]) {
        transaction {
            run("DELETE FROM identity;", bind: [])

            for (index, identity) in identities.enumerated() {
                guard let json = encode(identity) else { continue }

                run("INSERT INTO identity (id, position, json) VALUES (?, ?, ?);",
                    bind: [identity.id, index, json])
            }
        }
    }

    /// The folder the window was left on, so a launch reopens where it closed.
    func selectedMailboxID() -> String? {
        meta("selected_mailbox")
    }

    func setSelectedMailboxID(_ id: String?) {
        guard let id else {
            return
        }

        setMeta("selected_mailbox", id)
    }

    // MARK: - Messages

    /// One folder's newest messages, ordered the way the server orders them —
    /// `receivedAt` descending, which is deterministic and reproducible from
    /// fields already held, so no query-position mirroring is needed.
    func page(mailboxID: String, limit: Int) -> [EmailPreview] {
        query("""
        SELECT e.json FROM email e
        JOIN email_mailbox m ON m.email_id = e.id
        WHERE m.mailbox_id = ?
        ORDER BY e.received_at DESC
        LIMIT ?;
        """, bind: [mailboxID, limit]) { $0.text(0) }
            .compactMap { decode(EmailPreview.self, from: $0) }
    }

    func store(previews: [EmailPreview]) {
        guard !previews.isEmpty else {
            return
        }

        transaction {
            for preview in previews {
                guard let json = encode(preview) else { continue }

                run("INSERT OR REPLACE INTO email (id, thread_id, received_at, json) VALUES (?, ?, ?, ?);",
                    bind: [
                        preview.id,
                        preview.threadId,
                        preview.receivedAt?.timeIntervalSinceReferenceDate ?? 0,
                        json
                    ])

                // Membership is rewritten wholesale: a move is the same message
                // in a different folder, and a stale row here would leave it
                // showing in both.
                run("DELETE FROM email_mailbox WHERE email_id = ?;", bind: [preview.id])

                for (mailboxID, isIn) in preview.mailboxIds ?? [:] where isIn {
                    run("INSERT OR REPLACE INTO email_mailbox (email_id, mailbox_id) VALUES (?, ?);",
                        bind: [preview.id, mailboxID])
                }
            }
        }
    }

    func remove(emailIDs: some Collection<String>) {
        guard !emailIDs.isEmpty else {
            return
        }

        transaction {
            for id in emailIDs {
                run("DELETE FROM email WHERE id = ?;", bind: [id])
                run("DELETE FROM email_mailbox WHERE email_id = ?;", bind: [id])
                run("DELETE FROM email_body WHERE id = ?;", bind: [id])
            }
        }
    }

    /// One message by id, wherever it currently sits. Used to build an
    /// optimistic update for a message that has already left the visible list.
    func message(id: String) -> EmailPreview? {
        query("SELECT json FROM email WHERE id = ?;", bind: [id]) { $0.text(0) }
            .compactMap { decode(EmailPreview.self, from: $0) }
            .first
    }

    // MARK: - Outbox

    /// Queues a change, replacing any pending change it supersedes. Ordering is
    /// by insertion, so "mark read, then archive" replays in that order.
    func enqueue(_ entry: OutboxEntry) {
        guard let json = encode(entry.action) else {
            return
        }

        transaction {
            run("DELETE FROM outbox WHERE email_id = ? AND action_key = ?;",
                bind: [entry.emailID, entry.coalescingKey])
            run("""
            INSERT INTO outbox (id, email_id, action_key, action, attempts, queued_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """, bind: [
                entry.id.uuidString,
                entry.emailID,
                entry.coalescingKey,
                json,
                entry.attempts,
                entry.queuedAt.timeIntervalSinceReferenceDate
            ])
        }
    }

    /// Everything still owed to the server, oldest first.
    func pendingOutbox() -> [OutboxEntry] {
        query("SELECT id, email_id, action, attempts, queued_at FROM outbox ORDER BY sequence;", bind: []) { row in
            entry(from: row)
        }
    }

    /// What is still owed for one message, so a server delta can be corrected
    /// before it overwrites a change the user has already seen applied.
    func pendingOutbox(for emailID: String) -> [OutboxEntry] {
        query("""
        SELECT id, email_id, action, attempts, queued_at FROM outbox
        WHERE email_id = ? ORDER BY sequence;
        """, bind: [emailID]) { row in
            entry(from: row)
        }
    }

    func removeOutbox(id: UUID) {
        run("DELETE FROM outbox WHERE id = ?;", bind: [id.uuidString])
    }

    func recordOutboxAttempt(id: UUID) {
        run("UPDATE outbox SET attempts = attempts + 1 WHERE id = ?;", bind: [id.uuidString])
    }

    private func entry(from row: Row) -> OutboxEntry? {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
              let emailID = row.text(1),
              let json = row.text(2),
              let action = decode(OutboxEntry.Action.self, from: json) else {
            return nil
        }

        return OutboxEntry(
            id: id,
            emailID: emailID,
            action: action,
            attempts: row.int(3),
            queuedAt: Date(timeIntervalSinceReferenceDate: row.double(4))
        )
    }

    // MARK: - Bodies

    /// A cached body is never stale: everything `EmailDetail` carries beyond its
    /// keywords is immutable, and the reader takes the keywords from the list it
    /// was opened from.
    func body(for emailID: String) -> EmailDetail? {
        guard let json = query("SELECT json FROM email_body WHERE id = ?;", bind: [emailID], read: { $0.text(0) }).first,
              let detail = decode(EmailDetail.self, from: json) else {
            return nil
        }

        run("UPDATE email_body SET touched_at = ? WHERE id = ?;",
            bind: [Date.timeIntervalSinceReferenceDate, emailID])

        return detail
    }

    func store(body: EmailDetail) {
        guard let json = encode(body) else {
            return
        }

        run("INSERT OR REPLACE INTO email_body (id, json, bytes, touched_at) VALUES (?, ?, ?, ?);",
            bind: [body.id, json, json.utf8.count, Date.timeIntervalSinceReferenceDate])

        evictBodiesIfNeeded()
    }

    private func evictBodiesIfNeeded() {
        let total = query("SELECT SUM(bytes) FROM email_body;", bind: []) { $0.int(0) }.first ?? 0
        guard total > Self.bodyByteBudget else {
            return
        }

        // Drop the older half rather than trimming to the line, so eviction runs
        // rarely instead of on every store once the cache is full.
        run("""
        DELETE FROM email_body WHERE id IN (
            SELECT id FROM email_body
            ORDER BY touched_at ASC
            LIMIT (SELECT COUNT(*) / 2 FROM email_body)
        );
        """, bind: [])
    }

    // MARK: - Attachment blobs

    /// Blob content is immutable for the life of its `blobId`, so a cached
    /// attachment never needs checking against the server.
    ///
    /// The id is the server's to choose and can hold anything, so it is hashed
    /// rather than trusted as a filename.
    private func blobURL(for blobID: String) -> URL? {
        let digest = SHA256.hash(data: Data(blobID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()

        return blobDirectory?.appending(path: name)
    }

    func blob(for blobID: String) -> Data? {
        guard let url = blobURL(for: blobID), let data = try? Data(contentsOf: url) else {
            return nil
        }

        // Touch it so eviction counts it as recently used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

        return data
    }

    func store(blob: Data, for blobID: String) {
        guard let url = blobURL(for: blobID) else {
            return
        }

        try? blob.write(to: url, options: .atomic)
        evictBlobsIfNeeded()
    }

    private func evictBlobsIfNeeded() {
        guard let blobDirectory,
              let names = try? FileManager.default.contentsOfDirectory(
                at: blobDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
              ) else {
            return
        }

        let files = names.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else {
                return nil
            }

            return (url, size, date)
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > Self.blobByteBudget else {
            return
        }

        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > Self.blobByteBudget / 2 else {
                break
            }

            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    // MARK: - SQLite plumbing

    private func meta(_ key: String) -> String? {
        query("SELECT value FROM meta WHERE key = ?;", bind: [key]) { $0.text(0) }.first
    }

    private func setMeta(_ key: String, _ value: String) {
        run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);", bind: [key, value])
    }

    private func execute(_ sql: String) {
        guard let db else {
            return
        }

        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func transaction(_ body: () -> Void) {
        execute("BEGIN IMMEDIATE;")
        body()
        execute("COMMIT;")
    }

    private func run(_ sql: String, bind values: [Any?]) {
        guard let statement = prepared(sql, bind: values) else {
            return
        }

        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func query<T>(_ sql: String, bind values: [Any?], read: (Row) -> T?) -> [T] {
        guard let statement = prepared(sql, bind: values) else {
            return []
        }

        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = read(Row(statement: statement)) {
                results.append(value)
            }
        }

        return results
    }

    private func prepared(_ sql: String, bind values: [Any?]) -> OpaquePointer? {
        guard let db else {
            return nil
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)

            switch value {
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double:
                sqlite3_bind_double(statement, index, number)
            default:
                sqlite3_bind_null(statement, index)
            }
        }

        return statement
    }

    /// One row of a result set, read by column index.
    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else {
                return nil
            }

            return String(cString: bytes)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        try? decoder.decode(type, from: Data(json.utf8))
    }
}

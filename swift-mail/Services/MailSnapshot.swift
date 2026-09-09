import Foundation

/// The last-known state of an account, written to disk so a relaunch can show
/// mail before the network answers.
///
/// The two `*State` values are the valuable part. They are JMAP's opaque state
/// cursors (RFC 8620 §5.2), and keeping them across launches is what lets the
/// first sync ask `Email/changes` for a delta instead of re-querying the
/// mailbox from scratch. The previews alongside them are what fills the first
/// frame while that delta is in flight.
///
/// This is a cache, not a store: every field is recoverable from the server, so
/// a schema bump, a decode failure or a different account discards the file
/// rather than migrating it.
nonisolated struct MailSnapshot: Codable {
    /// Bump on any change older files can't satisfy. A mismatch throws the
    /// snapshot away, which costs one slow launch and nothing else.
    static let currentSchema = 1

    var schema = MailSnapshot.currentSchema
    /// Which account this belongs to, so signing into a different one is never
    /// handed the previous account's mail.
    var accountKey: String
    var emailState: String?
    var mailboxState: String?
    var mailboxes: [Mailbox] = []
    var identities: [MailIdentity] = []
    var selectedMailboxID: String?
    /// The first page of each folder visited, keyed by mailbox id. Only the
    /// unfiltered listing is ever stored — see `MailStore.saveSnapshot()`.
    var previews: [String: [EmailPreview]] = [:]
    var savedAt = Date()
}

/// Reads and writes the snapshot file.
///
/// Deliberately plain functions rather than an actor: the load happens once in
/// `MailStore.init()`, where there is nothing to await from, and the caller
/// dispatches saves off the main actor. Writes are atomic and last-writer-wins,
/// which is the right contract for a cache — a save that loses a race costs a
/// slightly staler first frame and nothing else.
nonisolated enum MailSnapshotStore {
    private static let fileName = "snapshot.json"

    /// `nil` only if Application Support is unreachable, in which case the app
    /// behaves exactly as it did before this file existed.
    private static var fileURL: URL? {
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

        return directory.appending(path: fileName)
    }

    static func load(accountKey: String, from url: URL? = nil) -> MailSnapshot? {
        guard let fileURL = url ?? fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(MailSnapshot.self, from: data),
              snapshot.schema == MailSnapshot.currentSchema,
              snapshot.accountKey == accountKey else {
            return nil
        }

        return snapshot
    }

    static func save(_ snapshot: MailSnapshot, to url: URL? = nil) {
        guard let fileURL = url ?? fileURL, let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear(at url: URL? = nil) {
        guard let fileURL = url ?? fileURL else {
            return
        }

        try? FileManager.default.removeItem(at: fileURL)
    }
}

# SwiftMail

A native macOS mail client for JMAP accounts, written in Swift and SwiftUI.

It exists because the alternative for a Fastmail account on the Mac is a web
app in a browser wrapper. This is the same mail, spoken natively: one process,
no bundled runtime, and a cache that means the window has mail in it before the
network answers.

Built and tested against Fastmail. Any RFC 8620/8621 server should work.

---

## Memory

Measured on the same machine, both signed in to the same account, both left
running ~25 minutes with mail loaded. `phys_footprint` is the number Activity
Monitor shows as "Memory":

| | Processes | Memory |
|---|---:|---:|
| **SwiftMail** | 1 | **~101 MB** |
| Fastmail (Electron) | 5 | ~284 MB |

The Electron client's 284 MB is spread across a main process, a GPU helper and
three renderers. None of that is waste on Electron's part — it's the cost of
shipping a browser to run a web app. It just isn't a cost a native client has
to pay.

That gap is a consequence of the dependency policy below, not something that
was optimised for. Nobody profiled memory here; there simply isn't a runtime.

---

## Dependencies

**Zero third-party packages.** No SPM dependencies, no CocoaPods, no vendored
source. The entire dependency list is Apple's:

`SwiftUI` · `AppKit` · `Foundation` · `Combine` · `SQLite3` · `WebKit` ·
`QuickLook` · `UserNotifications` · `CryptoKit` · `Security` ·
`UniformTypeIdentifiers` · `FoundationModels`

This is a deliberate constraint, and it shapes the code more than any other
decision:

- **JSON-RPC over HTTP is `URLSession` and `JSONSerialization`.** JMAP is a
  small, well-specified protocol. A client library would be a layer to learn on
  top of a spec you have to read anyway.
- **The cache is SQLite through its C API** — prepared statements against
  `libsqlite3`. A wrapper would add a dependency to save the same statements.
- **The recipient field is `NSTokenField`.** Comma tokenising, drag and drop,
  token editing and the completion dropdown are all AppKit's. The app supplies
  the completions and nothing else.
- **Markdown is Apple's parser**, and Quick Look previews attachments — no
  per-file-type preview code exists.

A dependency is not free because it works. It is a thing that must be
understood, updated, audited and eventually replaced.

---

## JMAP coverage

Capabilities requested:

```
urn:ietf:params:jmap:core
urn:ietf:params:jmap:mail
urn:ietf:params:jmap:submission
urn:ietf:params:jmap:mail:snooze
```

Methods used: `Mailbox/get` · `Email/get` · `Email/query` · `Email/changes` ·
`Email/set` · `Thread/get` · `Identity/get` · `EmailSubmission/set`

What that buys, and where the spec is leaned on rather than skimmed:

- **Push, not polling.** `eventSourceUrl` (RFC 8620 §7.3) is consumed as a
  server-sent-event stream; each `StateChange` names the new state per type and
  only the types that moved are re-synced. Servers that don't advertise it fall
  back to polling type state.
- **Delta sync.** `Email/changes` against a stored state cursor, so a launch
  asks what changed rather than refetching a mailbox. The cursor is persisted,
  which is what lets a relaunch see everything that happened while the app was
  closed.
- **Anchored paging.** `Email/query` pages by `anchor`/`anchorOffset` rather
  than numeric position — mail arriving mid-scroll shifts every index, and
  position-based paging silently duplicates or skips a page.
- **Back-references.** `Email/get` reads its ids from the query in the same
  request (`#ids`), and `Thread/get` reads *its* ids from that result with the
  `/list/*/threadId` wildcard (RFC 8620 §3.7) — one round trip for a page of
  threaded mail.
- **Server-side threading.** `collapseThreads` on the query and
  `noneInThreadHaveKeyword` for muting, so a muted conversation is filtered by
  the server and still findable in search.
- **Patch semantics.** Keyword changes are sent as `keywords/$seen` patch paths
  rather than whole-object replacement, so two clients changing different
  keywords at once don't clobber each other.
- **Held sends.** Scheduled send and undo send are one mechanism — an
  `EmailSubmission` with a future `sendAt`, cancellable until it fires. The
  hold is the server's, so it survives quitting the app, and the delay is
  clamped to what the server said it will accept.
- **Delivery headers.** `header:X-Delivered-To:asAddresses` is requested as a
  parsed header, which is the only place a relayed message names which of your
  addresses it actually arrived at.
- **Limits are honoured.** `maxSizeUpload`, `maxObjectsInSet` and
  `maxDelayedSend` are read from the session and enforced before a request goes
  out, rather than discovered by having one rejected.

---

## Features

**Reading** — threaded or flat message list, expandable conversations, a
conversation strip in the reader, thread muting, Quick Look for attachments
with a configurable download folder, and remote images blocked by default with
a per-domain safe-sender list.

**Writing** — Markdown compose with live preview, drag-and-drop attachments,
multiple sending identities, and recipient autocomplete ranked from your own
Sent mail: frequency aged on a 90-day half-life, so who you wrote to last week
outranks a long-dead thread.

**Sending** — scheduled send and undo send on one server-held mechanism, with a
warning if you try to quit while something is still recallable.

**Organising** — colour tags mapping your aliases (including `*@domain`
wildcards) to a separated inbox, sweep to bulk-move by search query, swipe
actions, snooze, per-mailbox notifications and a dock badge.

**Searching** — power syntax (`from:ana subject:"q3 report" after:7d -is:read`,
`in:all`) translated to a server-side `Email/query` filter, so paging keeps
working on the result.

**Offline** — everything is cached in SQLite and every mutation goes through an
outbox: the change is applied to the screen immediately, queued durably, and
replayed in order. Where server state and a pending change disagree, the
pending change wins until it drains. A change the server finally refuses is
rolled back and the screen put back to the truth.

**Safety** — a sender-impersonation warning fires when a display name claims a
brand the sending domain doesn't belong to: `myGov` from `prosa.ai`, `ANZ` from
`anzsecurityemail.com`. It's a table of brands and their real sending domains,
not a model — precise where it fires and silent everywhere else. It only
suggests; nothing is filed automatically.

**Apple Intelligence** *(optional, both toggleable)* — runs entirely on-device
via `FoundationModels`; no part of a message leaves the Mac.

- *Thread summaries* for conversations of 3+ messages, streamed into the
  reader as they generate.
- *Scam flagging* for unfiled mail from senders you've never written to, which
  catches what the brand table structurally cannot: a casino promising £1,450
  from a domain nobody has heard of impersonates nothing.

Both only suggest. The model is a content filter, not a security control.

---

## How it's built

**13,900 lines of Swift across 32 files, and 191 tests across 22 files.**

Some conventions that are load-bearing rather than stylistic:

**Comments say why, not what.** Every non-obvious decision carries the reason
it was made and, where it's a deliberate corner, what the ceiling is and when
to raise it. The SSE parser explains why it frames bytes by hand instead of
using `AsyncLineSequence`; the reader's remote-content notice explains why it
carries a line limit. Both are one-line changes that cost hours to rediscover.

**Fix at the shared point** — a guard in the one function every caller routes
through, not the same guard in every caller.

**Native platform feature over hand-rolled UI**, standard library over a
dependency, one line over fifty — but never at the cost of correctness at a
trust boundary, error handling that prevents data loss, or accessibility.

**Non-trivial logic leaves a runnable check.** Not a per-function suite: one
test that fails if the logic breaks. Where a prompt is involved, the test cases
are the model's *actual* observed output rather than what it ought to have
returned — the empty-list and duplicate-entry tests exist because the model did
both.

**Model output is treated as untrusted.** Prompts label message content as
data; `@Generable` constrains output to a closed set so there is no free-form
action to hijack; verdicts only ever draw a banner. A message that talks the
model into "ordinary" gets exactly what it would have got with no triage at
all.

---

## Building

Requires **macOS 26.5** and **Xcode 26.6** or later.

```bash
git clone https://github.com/declan-wade/swift-mail.git
cd swift-mail
open swift-mail.xcodeproj
```

No package resolution step — there are no packages.

```bash
xcodebuild -project swift-mail.xcodeproj -scheme swift-mail -destination 'platform=macOS' test
```

### Signing in

Fastmail: create an API token with **Mail** scope under Settings → Privacy &
Security → Integrations, and paste it along with your JMAP session URL
(`https://api.fastmail.com/jmap/session`). The token is stored in the Keychain
as a generic password and is never written to disk anywhere else.

Any other JMAP server: its session URL and a bearer token.

### Sandbox

The app is sandboxed and holds exactly four entitlements: outbound network,
read/write to `~/Downloads`, read/write to folders you pick yourself, and
app-scoped bookmarks so a chosen download folder survives a relaunch.

The Apple Intelligence features additionally need Apple Intelligence enabled in
System Settings. **Settings → Advanced** reports exactly what the model is
doing and includes a self-test that runs the real generation path, so "it never
fires" resolves to either a result or a named reason.

---

## Not implemented

Calendars, contacts, more than one account at a time,
`urn:ietf:params:jmap:vacationresponse`, and Sieve rule editing. All are
reachable from the same session object; none are here yet.

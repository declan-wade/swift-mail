import Combine
import Foundation
import FoundationModels

/// What a long thread amounts to.
///
/// Small on purpose: every property becomes part of the JSON schema sent to
/// the model, and the schema is charged against the same 4,096-token window as
/// the thread itself. Names the model can infer carry no `@Guide`.
@Generable
struct ThreadSummary: Equatable {
    @Guide(description: "What this thread is about, in one sentence")
    var gist: String

    @Guide(description: "What was decided or settled, most important first")
    @Guide(.maximumCount(4))
    var points: [String]

    @Guide(description: "What the reader still needs to do. Empty if nothing is asked of them.")
    @Guide(.maximumCount(3))
    var actions: [String]
}

/// Summarises a mail thread with the on-device model.
///
/// A new session per thread rather than one reused across them: each thread is
/// a fresh question, and a session that accumulated every thread's transcript
/// would exhaust the context window within a few messages.
@MainActor
final class ThreadSummarizer: ObservableObject {
    /// Below this a thread is short enough to read, and a summary is a slower,
    /// lossier version of the messages already on screen.
    static let minimumMessages = 3

    enum State: Equatable {
        case idle
        case unavailable(String)
        case summarizing
        case ready(ThreadSummary)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Filled in as the model streams, so the summary appears line by line
    /// rather than after a silent pause.
    @Published private(set) var partial: ThreadSummary.PartiallyGenerated?

    private let model = SystemLanguageModel.default
    private var task: Task<Void, Never>?
    /// Summaries already produced this session, by thread id. Re-reading a
    /// thread shouldn't re-run the model, and the answer wouldn't differ.
    private var cache: [String: ThreadSummary] = [:]
    private var summarizedThreadID: String?

    /// Whether a thread is worth summarising at all.
    nonisolated static func qualifies(messageCount: Int) -> Bool {
        messageCount >= minimumMessages
    }

    var isAvailable: Bool {
        model.isAvailable
    }

    /// What Settings should say about the model, so the toggle can explain
    /// itself rather than sitting on next to a feature that silently can't run.
    static var systemAdvice: String? {
        advice(for: SystemLanguageModel.default.availability)
    }

    // MARK: - Diagnostics

    /// The availability case, named rather than described, so the Advanced pane
    /// reports what the framework actually said instead of a paraphrase.
    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Available"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off"
        case .unavailable(.deviceNotEligible): "This Mac isn’t eligible"
        case .unavailable(.modelNotReady): "Model not ready (downloading)"
        case .unavailable(let reason): "Unavailable (\(reason))"
        }
    }

    /// Whether the model handles the language the Mac is set to. An
    /// unsupported locale fails at generation time rather than at availability,
    /// which is the kind of thing that reads as "it just doesn't work".
    static var localeDescription: String {
        let locale = Locale.current
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier

        return SystemLanguageModel.default.supportsLocale(locale)
            ? "\(name) — supported"
            : "\(name) — not supported"
    }

    static var contextSizeDescription: String {
        "\(SystemLanguageModel.default.contextSize) tokens"
    }

    /// Runs the real path — same instructions, same `ThreadSummary` schema —
    /// against a fixed three-message thread, and says what came back.
    ///
    /// This exists because every other line in the pane describes conditions,
    /// and conditions looking right is not the same as the thing working. One
    /// click turns "it never fires" into either a summary or a named error.
    static func selfTest() async -> String {
        guard let advice = advice(for: SystemLanguageModel.default.availability) else {
            return await generateTestSummary()
        }

        guard case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability else {
            return advice
        }

        return "This Mac isn’t eligible for Apple Intelligence."
    }

    private static func generateTestSummary() async -> String {
        let sample = """
            Subject: Thursday review
            1. Ana, today: Can we move Thursday's review to Friday?
            2. Ben, today: Friday works for me, any time before noon.
            3. Ana, today: Booked for 10am Friday.
            """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: sample,
                generating: ThreadSummary.self,
                options: GenerationOptions(sampling: .greedy)
            )

            return "Worked — “\(response.content.gist)”"
        } catch {
            return message(for: error)
        }
    }

    static var isSupportedOnThisMac: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
            return false
        }

        return true
    }

    /// Summarises `messages`, or explains why it can't.
    ///
    /// Calling this again for the same thread is a no-op, which is what lets
    /// the view drive it straight from `onChange` without tracking whether a
    /// run is already in flight.
    func summarize(threadID: String, subject: String, messages: [EmailPreview]) {
        guard summarizedThreadID != threadID else {
            return
        }

        task?.cancel()
        summarizedThreadID = threadID
        partial = nil

        if let cached = cache[threadID] {
            state = .ready(cached)
            return
        }

        guard Self.qualifies(messageCount: messages.count) else {
            state = .idle
            return
        }

        guard case .available = model.availability else {
            // No advice means nothing worth saying, so the pane stays silent
            // rather than carrying a notice the reader can't act on.
            state = Self.advice(for: model.availability).map(State.unavailable) ?? .idle
            return
        }

        state = .summarizing
        task = Task { [weak self] in
            await self?.run(threadID: threadID, subject: subject, messages: messages)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        summarizedThreadID = nil
        partial = nil
        state = .idle
    }

    private func run(threadID: String, subject: String, messages: [EmailPreview]) async {
        let session = LanguageModelSession(instructions: Self.instructions)
        // Loads the model while the transcript is still being measured, so the
        // first token doesn't wait on both.
        session.prewarm()

        let transcript = await Self.fittedTranscript(
            subject: subject,
            messages: messages,
            model: model
        )

        do {
            let stream = session.streamResponse(
                to: transcript,
                generating: ThreadSummary.self,
                // Greedy: the same thread should summarise the same way every
                // time. A summary that reworded itself on each read would come
                // across as the app being unsure.
                options: GenerationOptions(sampling: .greedy)
            )

            // Each snapshot carries both the partial value for the view and
            // the raw content it was decoded from; keeping the last raw one is
            // what turns the stream into a finished `ThreadSummary` without a
            // second request.
            var generated: GeneratedContent?

            for try await chunk in stream {
                try Task.checkCancellation()
                partial = chunk.content
                generated = chunk.rawContent
            }

            try Task.checkCancellation()

            guard let generated else {
                throw LanguageModelSession.GenerationError.decodingFailure(
                    .init(debugDescription: "The model returned no content.")
                )
            }

            let summary = try ThreadSummary(generated)
            cache[threadID] = summary
            state = .ready(summary)
        } catch is CancellationError {
            return
        } catch {
            // A half-streamed summary is worse than none: it reads as a
            // complete answer that happens to be wrong.
            partial = nil
            state = .failed(Self.message(for: error))
            summarizedThreadID = nil
        }
    }

    // MARK: - Prompting

    /// Kept to three short directions. Instructions are charged to the same
    /// window as the thread, and every token spent here is a message that
    /// doesn't fit.
    static let instructions = """
        You summarise email threads for the person who received them.
        Be specific and factual: name who said what, and never invent detail.
        Say only what the messages say.
        """

    /// Hard ceiling on messages fed to the model, before token budgeting. The
    /// recent end of a long thread is what a reader needs catching up on.
    static let maximumMessages = 20
    /// Per-message character budget. Fastmail's `preview` runs to a couple of
    /// hundred characters, so this rarely truncates — it's the guard against
    /// one enormous message crowding out the rest of the thread.
    static let maximumCharactersPerMessage = 400
    /// Room set aside for the instructions, the `ThreadSummary` schema and the
    /// model's own answer.
    static let reservedTokens = 1_200

    /// The thread as text, newest messages retained, oldest dropped until it
    /// fits the context window.
    ///
    /// `tokenCount(for:)` is asked rather than estimated because the cost of
    /// being wrong is `exceededContextWindowSize` — a failed summary — and the
    /// model can answer exactly. The loop is bounded: a handful of measured
    /// attempts, then whatever is left.
    nonisolated static func fittedTranscript(
        subject: String,
        messages: [EmailPreview],
        model: SystemLanguageModel
    ) async -> String {
        var kept = Array(messages.suffix(maximumMessages))

        // Instructions, the generated schema and the response itself all draw
        // on the same window, so the thread only gets a share of it.
        let budget = max(512, model.contextSize - reservedTokens)

        for _ in 0..<4 {
            let text = transcript(subject: subject, messages: kept)

            guard kept.count > 2,
                  let tokens = try? await model.tokenCount(for: Prompt(text)),
                  tokens > budget else {
                return text
            }

            kept = Array(kept.suffix(droppingOldest(from: kept.count)))
        }

        return transcript(subject: subject, messages: kept)
    }

    /// How many messages to keep on the next attempt: a quarter goes, rather
    /// than one at a time, which would spend more measurements than it saves.
    /// Never drops below two — one message isn't a thread.
    nonisolated static func droppingOldest(from count: Int) -> Int {
        max(2, count - max(1, count / 4))
    }

    /// One line per message: who, when, and what it opened with.
    ///
    /// Built from `preview` because that is what the thread already has in
    /// memory — full bodies would mean a fetch per message and would exhaust
    /// the window on a thread of any length.
    nonisolated static func transcript(subject: String, messages: [EmailPreview]) -> String {
        let lines = messages.enumerated().map { index, message in
            let sender = message.from?.first?.name?.nilIfEmpty ?? message.from?.first?.email ?? "Unknown"
            let date = message.receivedAt.map { DateFormatter.mailShort.string(from: $0) } ?? ""
            let body = (message.preview?.nilIfEmpty ?? "(no text)")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(maximumCharactersPerMessage)

            return "\(index + 1). \(sender), \(date): \(body)"
        }

        return """
            Subject: \(subject)

            \(lines.joined(separator: "\n"))
            """
    }

    // MARK: - Availability and errors

    /// What to tell the reader about the model being unusable, or nil when
    /// there is nothing worth saying.
    ///
    /// A Mac that isn't eligible never will be, so a notice about it on every
    /// long thread is a standing complaint about hardware rather than
    /// something anyone can act on — that case says nothing and the summary
    /// simply doesn't appear. The others are all temporary and fixable, which
    /// is what makes them worth a line: without one, a reader who asked for
    /// this feature would just see it missing.
    nonisolated static func advice(for availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available, .unavailable(.deviceNotEligible):
            nil
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings to summarise threads."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still getting ready. Try again shortly."
        case .unavailable:
            "Apple Intelligence isn’t available right now."
        }
    }

    /// Plain sentences, because the framework's own messages name types the
    /// reader has no way to act on.
    nonisolated static func message(for error: Error) -> String {
        switch error {
        case LanguageModelSession.GenerationError.exceededContextWindowSize:
            "This thread is too long to summarise."
        case LanguageModelSession.GenerationError.guardrailViolation,
             LanguageModelSession.GenerationError.refusal:
            "Apple Intelligence wouldn’t summarise this thread."
        case LanguageModelSession.GenerationError.unsupportedLanguageOrLocale:
            "Apple Intelligence doesn’t support this thread’s language yet."
        case LanguageModelSession.GenerationError.rateLimited:
            "Too many summaries at once. Try again in a moment."
        case LanguageModelSession.GenerationError.assetsUnavailable:
            "Apple Intelligence isn’t ready yet. Try again shortly."
        default:
            "Couldn’t summarise this thread."
        }
    }
}

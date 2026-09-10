import Foundation
import FoundationModels

/// What the on-device model is doing, and what to say when it can't help.
///
/// Shared by every feature that prompts the model. Two copies of the error
/// mapping would drift, and the reader would get a different sentence for the
/// same failure depending on which part of the app hit it.
nonisolated enum IntelligenceStatus {
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// What to tell the reader about the model being unusable, or nil when
    /// there is nothing worth saying.
    ///
    /// A Mac that isn't eligible never will be, so a notice about it on every
    /// message is a standing complaint about hardware rather than something
    /// anyone can act on — that case says nothing and the feature simply
    /// doesn't appear. The others are all temporary and fixable, which is what
    /// makes them worth a line.
    static func advice(for availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available, .unavailable(.deviceNotEligible):
            nil
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still getting ready. Try again shortly."
        case .unavailable:
            "Apple Intelligence isn’t available right now."
        }
    }

    static var currentAdvice: String? {
        advice(for: SystemLanguageModel.default.availability)
    }

    static var isSupportedOnThisMac: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
            return false
        }

        return true
    }

    /// Plain sentences, because the framework's own messages name types the
    /// reader has no way to act on.
    static func message(for error: Error) -> String {
        switch error {
        case LanguageModelSession.GenerationError.exceededContextWindowSize:
            "That was too long for Apple Intelligence to read."
        case LanguageModelSession.GenerationError.guardrailViolation,
             LanguageModelSession.GenerationError.refusal:
            "Apple Intelligence declined to answer."
        case LanguageModelSession.GenerationError.unsupportedLanguageOrLocale:
            "Apple Intelligence doesn’t support this language yet."
        case LanguageModelSession.GenerationError.rateLimited:
            "Too many requests at once. Try again in a moment."
        case LanguageModelSession.GenerationError.assetsUnavailable:
            "Apple Intelligence isn’t ready yet. Try again shortly."
        default:
            "Apple Intelligence couldn’t finish."
        }
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
}

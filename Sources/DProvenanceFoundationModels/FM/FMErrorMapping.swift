#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FMGenerationErrorPayload {
    /// Maps any error thrown by a FoundationModels generation into the frozen
    /// error vocabulary. `GenerationError` is non-frozen, so unknown future
    /// cases map to `.unknown` instead of crashing.
    ///
    /// `.refusal`: the Refusal's `explanation` is NEVER awaited (fetching it
    /// triggers a fresh generation), and the verified SDK exposes no public
    /// accessor for the refusal's transcript entries, so `refusalEntryCount`
    /// is nil until the SDK surfaces one.
    public init(error: any Error, turnIndex: Int, redaction: FMRedactionPolicy) {
        func redacted(_ text: String) -> FMRedactedText {
            FMRedactedText(text, redaction: redaction.errorMessages, redactor: redaction.redactor)
        }

        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize(let context):
                self.init(kind: .exceededContextWindowSize, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .assetsUnavailable(let context):
                self.init(kind: .assetsUnavailable, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .guardrailViolation(let context):
                self.init(kind: .guardrailViolation, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .unsupportedGuide(let context):
                self.init(kind: .unsupportedGuide, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .unsupportedLanguageOrLocale(let context):
                self.init(kind: .unsupportedLanguageOrLocale, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .decodingFailure(let context):
                self.init(kind: .decodingFailure, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .rateLimited(let context):
                self.init(kind: .rateLimited, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .concurrentRequests(let context):
                self.init(kind: .concurrentRequests, message: redacted(context.debugDescription), turnIndex: turnIndex)
            case .refusal(_, let context):
                self.init(kind: .refusal, message: redacted(context.debugDescription), refusalEntryCount: nil, turnIndex: turnIndex)
            @unknown default:
                self.init(kind: .unknown, message: redacted(generationError.localizedDescription), turnIndex: turnIndex)
            }
        } else if let toolCallError = error as? LanguageModelSession.ToolCallError {
            self.init(
                kind: .toolCallError,
                message: redacted(toolCallError.underlyingError.localizedDescription),
                toolName: toolCallError.tool.name,
                turnIndex: turnIndex
            )
        } else {
            self.init(kind: .unknown, message: redacted(error.localizedDescription), turnIndex: turnIndex)
        }
    }
}
#endif

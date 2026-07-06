import Foundation
import DProvenanceKit
import DProvenanceFoundationModels
import DProvenanceOTel

// Well-known GenAI semantic-convention values this bridge emits. The `gen_ai.*`
// request-parameter keys are not exposed by `GenAIAttributes` fields, so they are
// spelled here as the standard semconv strings.
private enum FMGenAI {
    static let provider = "apple.foundationmodels"
    /// Apple's on-device system model has no public version identifier, so we emit a
    /// stable placeholder id that lets GenAI-aware backends (e.g. Langfuse) group
    /// generations. Callers who can pin an OS-to-model revision can post-process it.
    static let model = "apple.foundationmodels.system"

    static let chat = "chat"
    static let executeTool = "execute_tool"

    static let temperatureKey = "gen_ai.request.temperature"
    static let maxTokensKey = "gen_ai.request.max_tokens"
}

/// Makes FoundationModels traces classify themselves out of the box when exported
/// through the OTel bridge.
///
/// This is the missing last mile of the flagship path — Apple Foundation Models →
/// Langfuse. GenAI-aware backends classify generations from `gen_ai.*` **span**
/// attributes only; without a conformance here every FM event exported as a bare
/// `dpk.*` span and no generation was ever recognized. Linking this target supplies
/// the mapping with no code change at the call site:
///
/// ```swift
/// import DProvenanceFoundationModelsOTel   // just importing/linking is enough
/// // ...export the FM run as usual; prompts, responses, and tool calls now carry gen_ai.*
/// ```
///
/// The mapper resolves semantics via a runtime `as? OTelSemanticsProviding` cast, so
/// this retroactive conformance takes effect whenever the target is linked — no OTel
/// or FoundationModels base-module change required.
///
/// Honest scope: on-device FoundationModels exposes **no consumed-token counts**, so
/// no `gen_ai.usage.*` is emitted (this is classification, not cost accounting).
/// Errors, availability, stream snapshots, and instructions are left unpromoted.
extension FoundationModelTraceEvent: OTelSemanticsProviding {
    public var otelSemantics: GenAIAttributes? {
        switch self {
        case .prompt(let payload):
            var extra: [OTLPKeyValue] = []
            if let temperature = payload.options?.temperature {
                extra.append(.double(FMGenAI.temperatureKey, temperature))
            }
            if let maxTokens = payload.options?.maximumResponseTokens {
                extra.append(.int(FMGenAI.maxTokensKey, Int64(maxTokens)))
            }
            return GenAIAttributes(
                operationName: FMGenAI.chat,
                requestModel: FMGenAI.model,
                providerName: FMGenAI.provider,
                extra: extra
            )

        case .response:
            return GenAIAttributes(
                operationName: FMGenAI.chat,
                responseModel: FMGenAI.model,
                providerName: FMGenAI.provider
            )

        case .toolCall(let payload):
            return GenAIAttributes(
                operationName: FMGenAI.executeTool,
                toolName: payload.toolName,
                providerName: FMGenAI.provider
            )

        case .toolOutput(let payload):
            return GenAIAttributes(
                operationName: FMGenAI.executeTool,
                toolName: payload.toolName,
                providerName: FMGenAI.provider
            )

        case .generationError(let payload):
            // A failed generation: classify it and stamp the error kind so the span
            // is marked ERROR. A tool-call error is an execute_tool failure; anything
            // else is a chat failure.
            if let tool = payload.toolName {
                return GenAIAttributes(
                    operationName: FMGenAI.executeTool,
                    toolName: tool,
                    providerName: FMGenAI.provider,
                    errorType: payload.kind.rawValue
                )
            }
            return GenAIAttributes(
                operationName: FMGenAI.chat,
                providerName: FMGenAI.provider,
                errorType: payload.kind.rawValue
            )

        case .instructions, .modelAvailability, .streamSnapshot, .unknownEntry:
            return nil
        }
    }

    public var otelEventName: String? {
        switch self {
        // semconv span-name convention is "{operation} {target}".
        case .prompt, .response:
            return "\(FMGenAI.chat) \(FMGenAI.model)"
        case .toolCall(let payload):
            return "\(FMGenAI.executeTool) \(payload.toolName)"
        case .toolOutput(let payload):
            return "\(FMGenAI.executeTool) \(payload.toolName)"
        case .generationError(let payload):
            if let tool = payload.toolName {
                return "\(FMGenAI.executeTool) \(tool)"
            }
            return "\(FMGenAI.chat) \(FMGenAI.model)"
        case .instructions, .modelAvailability, .streamSnapshot, .unknownEntry:
            return nil
        }
    }
}

import Foundation
import DProvenanceKit

/// The FoundationModels trace vocabulary. typeIdentifiers and priorities are
/// FROZEN (see the module header); payloads carry no volatile data — no entry
/// ids, no call ids, no timestamps — so live and post-hoc capture of the same
/// transcript are byte-exact equal.
public enum FoundationModelTraceEvent: TraceableEvent {
    case instructions(FMInstructionsPayload)
    case prompt(FMPromptPayload)
    case toolCall(FMToolCallPayload)
    case toolOutput(FMToolOutputPayload)
    case response(FMResponsePayload)
    case generationError(FMGenerationErrorPayload)
    case modelAvailability(FMModelAvailabilityPayload)
    case streamSnapshot(FMStreamSnapshotPayload)
    case unknownEntry(FMUnknownEntryPayload)

    public var typeIdentifier: String {
        switch self {
        case .instructions: return FMEventType.instructions
        case .prompt: return FMEventType.prompt
        case .toolCall: return FMEventType.toolCall
        case .toolOutput: return FMEventType.toolOutput
        case .response: return FMEventType.response
        case .generationError: return FMEventType.generationError
        case .modelAvailability: return FMEventType.modelAvailability
        case .streamSnapshot: return FMEventType.streamSnapshot
        case .unknownEntry: return FMEventType.unknownEntry
        }
    }

    public var priority: TracePriority {
        switch self {
        case .prompt, .response, .toolCall, .generationError: return .critical
        case .instructions, .toolOutput: return .structural
        case .modelAvailability, .unknownEntry: return .diagnostic
        case .streamSnapshot: return .telemetry
        }
    }

    /// Compact identity for the equivalence evaluator, e.g.
    /// "fm_tool_call:WeatherTool" or "fm_generation_error:refusal".
    /// Excludes indices and all content: two payloads differing only in
    /// turnIndex/invocationIndex have equal keys.
    public var semanticKey: String {
        switch self {
        case .toolCall(let payload): return "\(FMEventType.toolCall):\(payload.toolName)"
        case .toolOutput(let payload): return "\(FMEventType.toolOutput):\(payload.toolName)"
        case .generationError(let payload): return "\(FMEventType.generationError):\(payload.kind.rawValue)"
        case .modelAvailability(let payload): return "\(FMEventType.modelAvailability):\(payload.provider)"
        default: return typeIdentifier
        }
    }

    /// Bridge for AnyTraceableEvent-typed runs. Encodes with
    /// `JSONEncoder.OutputFormatting.sortedKeys` and no dates are present, so
    /// `rawJSON` is byte-deterministic across encodes. Encoding these payloads
    /// is total except for a non-finite `temperature`, in which case the
    /// envelope survives with an empty payload rather than crashing.
    public func eraseToAny() -> AnyTraceableEvent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawJSON: String
        if let data = try? encoder.encode(self) {
            rawJSON = String(decoding: data, as: UTF8.self)
        } else {
            rawJSON = "{}"
        }
        return AnyTraceableEvent(
            typeIdentifier: typeIdentifier,
            priorityValue: priority.rawValue,
            rawJSON: rawJSON
        )
    }
}

public struct FMInstructionsPayload: Codable, Sendable, Equatable {
    public var content: FMRedactedText
    /// Transcript order, NOT sorted: the order is deterministic per session
    /// construction and sorting would hide reordering regressions.
    public var toolNames: [String]
    public var toolDescriptions: [String: String]

    public init(content: FMRedactedText, toolNames: [String], toolDescriptions: [String: String] = [:]) {
        self.content = content
        self.toolNames = toolNames
        self.toolDescriptions = toolDescriptions
    }
}

public struct FMPromptPayload: Codable, Sendable, Equatable {
    public var content: FMRedactedText
    public var options: FMGenerationOptionsSnapshot?
    /// `Transcript.ResponseFormat.name` when the turn requested structured output.
    public var responseFormatName: String?
    /// 0-based ordinal of this prompt entry within the transcript.
    public var turnIndex: Int

    public init(
        content: FMRedactedText,
        options: FMGenerationOptionsSnapshot? = nil,
        responseFormatName: String? = nil,
        turnIndex: Int
    ) {
        self.content = content
        self.options = options
        self.responseFormatName = responseFormatName
        self.turnIndex = turnIndex
    }
}

public struct FMToolCallPayload: Codable, Sendable, Equatable {
    public var toolName: String
    /// Redaction over `GeneratedContent.jsonString` (verified: preserves key order).
    public var arguments: FMRedactedText
    public var turnIndex: Int
    /// k-th call of this toolName within the turn (0-based).
    public var invocationIndex: Int

    public init(toolName: String, arguments: FMRedactedText, turnIndex: Int, invocationIndex: Int) {
        self.toolName = toolName
        self.arguments = arguments
        self.turnIndex = turnIndex
        self.invocationIndex = invocationIndex
    }
}

public struct FMToolOutputPayload: Codable, Sendable, Equatable {
    public var toolName: String
    /// Joined segment text (text segments verbatim, structured segments as jsonString).
    public var content: FMRedactedText
    /// Live mode: the base tool threw (the error is then rethrown). Post-hoc
    /// ingestion cannot observe failure, so it always records false.
    public var isError: Bool
    public var turnIndex: Int
    /// Paired to the k-th same-name call within the turn by transcript order.
    /// Name+order pairing is a documented heuristic: the SDK does not expose a
    /// verified ToolOutput.id == ToolCall.id relationship.
    public var invocationIndex: Int

    public init(toolName: String, content: FMRedactedText, isError: Bool = false, turnIndex: Int, invocationIndex: Int) {
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.turnIndex = turnIndex
        self.invocationIndex = invocationIndex
    }
}

public struct FMResponsePayload: Codable, Sendable, Equatable {
    public var content: FMRedactedText
    /// Count only; asset ids are volatile and never recorded.
    public var assetIDCount: Int
    public var turnIndex: Int

    public init(content: FMRedactedText, assetIDCount: Int = 0, turnIndex: Int) {
        self.content = content
        self.assetIDCount = assetIDCount
        self.turnIndex = turnIndex
    }
}

public enum FMGenerationErrorKind: String, Codable, Sendable, Equatable {
    case exceededContextWindowSize, assetsUnavailable, guardrailViolation, unsupportedGuide,
         unsupportedLanguageOrLocale, decodingFailure, rateLimited, concurrentRequests,
         refusal, toolCallError, unknown
}

public struct FMGenerationErrorPayload: Codable, Sendable, Equatable {
    public var kind: FMGenerationErrorKind
    /// The error context's debugDescription, redacted per the errorMessages policy.
    public var message: FMRedactedText
    /// Set for `.toolCallError` only.
    public var toolName: String?
    /// `.refusal` only. The refusal's `explanation` is NEVER fetched — reading
    /// it triggers a fresh generation.
    public var refusalEntryCount: Int?
    public var turnIndex: Int

    public init(
        kind: FMGenerationErrorKind,
        message: FMRedactedText,
        toolName: String? = nil,
        refusalEntryCount: Int? = nil,
        turnIndex: Int
    ) {
        self.kind = kind
        self.message = message
        self.toolName = toolName
        self.refusalEntryCount = refusalEntryCount
        self.turnIndex = turnIndex
    }
}

public struct FMModelAvailabilityPayload: Codable, Sendable, Equatable {
    /// Provider identity hook so a future multi-provider vocabulary can
    /// distinguish availability sources without a payload change.
    public var provider: String
    public var isAvailable: Bool
    /// "device_not_eligible" | "apple_intelligence_not_enabled" | "model_not_ready" | "unknown"
    public var unavailableReason: String?
    public var contextSize: Int?

    public init(
        provider: String = "apple.foundationmodels",
        isAvailable: Bool,
        unavailableReason: String? = nil,
        contextSize: Int? = nil
    ) {
        self.provider = provider
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.contextSize = contextSize
    }
}

public struct FMStreamSnapshotPayload: Codable, Sendable, Equatable {
    public var snapshotIndex: Int
    /// Length only — telemetry never carries content.
    public var contentUTF8Count: Int
    public var turnIndex: Int

    public init(snapshotIndex: Int, contentUTF8Count: Int, turnIndex: Int) {
        self.snapshotIndex = snapshotIndex
        self.contentUTF8Count = contentUTF8Count
        self.turnIndex = turnIndex
    }
}

/// Forward-compat for transcript Entry kinds this version does not know.
public struct FMUnknownEntryPayload: Codable, Sendable, Equatable {
    /// The entry's CustomStringConvertible description, redacted per the
    /// errorMessages policy (unknown entries may carry content).
    public var kindDescription: FMRedactedText
    public var turnIndex: Int?

    public init(kindDescription: FMRedactedText, turnIndex: Int? = nil) {
        self.kindDescription = kindDescription
        self.turnIndex = turnIndex
    }
}

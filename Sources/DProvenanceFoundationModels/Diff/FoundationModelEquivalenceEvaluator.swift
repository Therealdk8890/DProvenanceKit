import Foundation
import DProvenanceKit

/// Deterministic FM-aware payload similarity for the alignment engine.
///
/// Scoring, in order:
/// - different typeIdentifier: 0.0;
/// - tool events with different toolName: 0.05 floor;
/// - equal content identity (FMRedactedText ==, hash-based, so it holds
///   cross-policy): 1.0;
/// - otherwise 0.55 base + 0.35 * whitespace-token Jaccard (requires .full
///   text on both sides) + 0.10 index-proximity tiebreaker.
///
/// Indices are deliberately weak: an inserted early turn shifts every
/// subsequent turnIndex, and that alone must not cascade mismatches
/// (pinned by test).
public struct FoundationModelEquivalenceEvaluator: TraceEquivalenceEvaluator, Sendable {
    public typealias Event = FoundationModelTraceEvent

    /// Versioned: feeds the alignment profileHash, so a scoring change must
    /// bump this identifier.
    public var evaluatorIdentifier: String { "fm-equivalence-v1" }

    public init() {}

    public func evaluateSimilarity(base: Event, comparison: Event) -> Double {
        guard base.typeIdentifier == comparison.typeIdentifier else { return 0.0 }
        if let baseName = base.fmToolName, let compName = comparison.fmToolName, baseName != compName {
            return 0.05
        }
        if Self.contentIdentity(base, comparison) {
            return 1.0
        }
        let jaccard = Self.whitespaceTokenJaccard(base.fmFullText, comparison.fmFullText)
        let proximity = Self.indexProximity(base.fmPrimaryIndex, comparison.fmPrimaryIndex)
        return 0.55 + 0.35 * jaccard + 0.10 * proximity
    }

    public func ambiguityThreshold(for event: Event) -> Double {
        switch event {
        case .toolCall, .toolOutput: return 0.6
        case .prompt, .response: return 0.5
        default: return 0.4
        }
    }

    /// Content identity excludes turn/invocation indices entirely.
    private static func contentIdentity(_ a: Event, _ b: Event) -> Bool {
        switch (a, b) {
        case (.instructions(let x), .instructions(let y)):
            return x.content == y.content && x.toolNames == y.toolNames
                && x.toolDescriptions == y.toolDescriptions
        case (.prompt(let x), .prompt(let y)):
            return x.content == y.content && x.responseFormatName == y.responseFormatName
        case (.toolCall(let x), .toolCall(let y)):
            return x.toolName == y.toolName && x.arguments == y.arguments
        case (.toolOutput(let x), .toolOutput(let y)):
            return x.toolName == y.toolName && x.content == y.content && x.isError == y.isError
        case (.response(let x), .response(let y)):
            return x.content == y.content && x.assetIDCount == y.assetIDCount
        case (.generationError(let x), .generationError(let y)):
            return x.kind == y.kind && x.toolName == y.toolName && x.message == y.message
        case (.modelAvailability(let x), .modelAvailability(let y)):
            return x == y
        case (.streamSnapshot(let x), .streamSnapshot(let y)):
            return x.contentUTF8Count == y.contentUTF8Count
        case (.unknownEntry(let x), .unknownEntry(let y)):
            return x.kindDescription == y.kindDescription
        default:
            return false
        }
    }

    private static func whitespaceTokenJaccard(_ a: String?, _ b: String?) -> Double {
        guard let a, let b else { return 0.0 }
        let tokensA = Set(a.split(whereSeparator: \.isWhitespace))
        let tokensB = Set(b.split(whereSeparator: \.isWhitespace))
        let union = tokensA.union(tokensB)
        guard !union.isEmpty else { return 0.0 }
        return Double(tokensA.intersection(tokensB).count) / Double(union.count)
    }

    private static func indexProximity(_ a: Int?, _ b: Int?) -> Double {
        switch (a, b) {
        case (nil, nil):
            return 1.0
        case (let a?, let b?):
            return max(0.0, 1.0 - Double(abs(a - b)) / 10.0)
        default:
            return 0.0
        }
    }
}

extension FoundationModelTraceEvent {
    fileprivate var fmToolName: String? {
        switch self {
        case .toolCall(let payload): return payload.toolName
        case .toolOutput(let payload): return payload.toolName
        default: return nil
        }
    }

    fileprivate var fmFullText: String? {
        switch self {
        case .instructions(let payload): return payload.content.text
        case .prompt(let payload): return payload.content.text
        case .toolCall(let payload): return payload.arguments.text
        case .toolOutput(let payload): return payload.content.text
        case .response(let payload): return payload.content.text
        case .generationError(let payload): return payload.message.text
        case .unknownEntry(let payload): return payload.kindDescription.text
        case .modelAvailability, .streamSnapshot: return nil
        }
    }

    fileprivate var fmPrimaryIndex: Int? {
        switch self {
        case .instructions, .modelAvailability: return nil
        case .prompt(let payload): return payload.turnIndex
        case .toolCall(let payload): return payload.turnIndex
        case .toolOutput(let payload): return payload.turnIndex
        case .response(let payload): return payload.turnIndex
        case .generationError(let payload): return payload.turnIndex
        case .streamSnapshot(let payload): return payload.turnIndex
        case .unknownEntry(let payload): return payload.turnIndex
        }
    }
}

public enum FoundationModelAlignment {
    /// The canonical alignment configuration for FM traces: the chosen
    /// profile plus this module's equivalence evaluator, type-erased the way
    /// core's `AlignmentConfiguration` requires.
    public static func configuration(
        profile: AlignmentProfile = .developerDebugV1
    ) -> AlignmentConfiguration<FoundationModelTraceEvent> {
        AlignmentConfiguration(
            profile: profile,
            equivalenceEvaluator: AnyEquivalenceEvaluator(
                identifier: "fm-equivalence-v1",
                evaluator: { FoundationModelEquivalenceEvaluator().evaluateSimilarity(base: $0, comparison: $1) },
                ambiguityThresholdFn: { FoundationModelEquivalenceEvaluator().ambiguityThreshold(for: $0) }
            )
        )
    }
}

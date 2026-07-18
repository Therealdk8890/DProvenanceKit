import Foundation
import CryptoKit

public enum AlignmentMode: String, Sendable, Equatable, Hashable {
    case linear
    case spanAware
    case fullGraph
}

public protocol TraceEquivalenceEvaluator: Sendable {
    associatedtype Event: TraceableEvent
    var evaluatorIdentifier: String { get }
    func evaluateSimilarity(base: Event, comparison: Event) -> Double
    func ambiguityThreshold(for event: Event) -> Double
}

public struct AlignmentProfile: Sendable, Equatable, Hashable {
    public enum Strategy: String, Sendable, Equatable, Hashable {
        case strictAudit = "strict_audit"
        case developerDebug = "developer_debug"
        case semanticExploration = "semantic_exploration"
    }
    
    public let strategy: Strategy
    public let version: Int
    
    public let typeWeight: Double
    public let payloadWeight: Double
    public let structuralWeight: Double
    public let temporalWeight: Double

    public let semanticThreshold: Double
    
    // Bounds for ambiguity
    public let maxAmbiguousCandidates: Int
    public let ambiguityDeltaThreshold: Double
    
    public let alignmentMode: AlignmentMode
    
    public init(
        strategy: Strategy,
        version: Int,
        typeWeight: Double,
        payloadWeight: Double,
        structuralWeight: Double,
        temporalWeight: Double,
        semanticThreshold: Double,
        maxAmbiguousCandidates: Int,
        ambiguityDeltaThreshold: Double,
        alignmentMode: AlignmentMode
    ) {
        self.strategy = strategy
        self.version = version
        self.typeWeight = typeWeight
        self.payloadWeight = payloadWeight
        self.structuralWeight = structuralWeight
        self.temporalWeight = temporalWeight
        self.semanticThreshold = semanticThreshold
        self.maxAmbiguousCandidates = maxAmbiguousCandidates
        self.ambiguityDeltaThreshold = ambiguityDeltaThreshold
        self.alignmentMode = alignmentMode
    }
    
    public static let strictAuditV1 = AlignmentProfile(
        strategy: .strictAudit,
        version: 1,
        typeWeight: 0.5,
        payloadWeight: 0.5,
        structuralWeight: 0.0,
        temporalWeight: 0.0,
        semanticThreshold: 0.99,
        maxAmbiguousCandidates: 1,
        ambiguityDeltaThreshold: 0.0,
        alignmentMode: .linear
    )
    
    public static let developerDebugV1 = AlignmentProfile(
        strategy: .developerDebug,
        version: 1,
        typeWeight: 0.4,
        payloadWeight: 0.4,
        structuralWeight: 0.15,
        temporalWeight: 0.05,
        semanticThreshold: 0.75,
        maxAmbiguousCandidates: 3,
        ambiguityDeltaThreshold: 0.10,
        alignmentMode: .spanAware
    )

    /// The matcher scan's scoring arithmetic, operation-for-operation identical to
    /// `AlignmentConfiguration.scoreMatch` (same contributions, accumulated in the same
    /// order, so the two produce bit-identical scores — change them together, and keep
    /// AlignmentFastPathParityTests passing). It lives on the non-generic profile, with the
    /// payload similarity passed in, so the O(base × comparison) scan runs fully specialized
    /// machine code instead of unspecialized generic calls.
    internal func combinedScore(
        typesEqual: Bool,
        payloadSim: Double,
        baseParentSpanID: String?,
        compParentSpanID: String?,
        baseSequence: UInt64,
        compSequence: UInt64
    ) -> Double {
        var score = 0.0

        // 1. Type Match
        let typeSim = typesEqual ? 1.0 : 0.0
        score += typeSim * typeWeight

        // 2. Payload Similarity
        score += payloadSim * payloadWeight

        // 3. Structural Context (Span Awareness)
        var structuralSim = 0.0
        if alignmentMode != .linear {
            if baseParentSpanID == compParentSpanID && baseParentSpanID != nil {
                structuralSim = 1.0
            } else if baseParentSpanID == nil && compParentSpanID == nil {
                structuralSim = 1.0
            }
        }
        score += structuralSim * structuralWeight

        // 4. Temporal Locality (rough heuristic based on sequence index distance)
        let seqDiff = abs(Int(baseSequence) - Int(compSequence))
        let tempSim = max(0.0, 1.0 - (Double(seqDiff) / 10.0))
        score += tempSim * temporalWeight

        return score
    }
}

public struct AnyEquivalenceEvaluator<T: TraceableEvent>: TraceEquivalenceEvaluator {
    public let evaluatorIdentifier: String
    private let evaluator: @Sendable (T, T) -> Double
    private let ambiguityThresholdFn: @Sendable (T) -> Double
    
    public init(
        identifier: String,
        evaluator: @escaping @Sendable (T, T) -> Double,
        ambiguityThresholdFn: @escaping @Sendable (T) -> Double = { _ in 0.4 }
    ) {
        self.evaluatorIdentifier = identifier
        self.evaluator = evaluator
        self.ambiguityThresholdFn = ambiguityThresholdFn
    }
    
    public func evaluateSimilarity(base: T, comparison: T) -> Double {
        return evaluator(base, comparison)
    }
    
    public func ambiguityThreshold(for event: T) -> Double {
        return ambiguityThresholdFn(event)
    }
}

public struct AlignmentConfiguration<T: TraceableEvent>: Sendable {
    public let profile: AlignmentProfile
    public let equivalenceEvaluator: AnyEquivalenceEvaluator<T>
    
    public let engineVersion: String = "1.0.0"
    
    public var profileHash: String {
        return AlignmentExecutionContract.computeProfileHash(
            profile: profile,
            evaluatorIdentifier: equivalenceEvaluator.evaluatorIdentifier,
            engineVersion: engineVersion
        )
    }
    
    public init(profile: AlignmentProfile, equivalenceEvaluator: AnyEquivalenceEvaluator<T>) {
        self.profile = profile
        self.equivalenceEvaluator = equivalenceEvaluator
    }
}

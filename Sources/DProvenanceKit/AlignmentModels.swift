import Foundation

/// A normalized heuristic score in the range 0.0-1.0 derived from weighted evidence contributions.
/// This represents the algorithmic strength of an alignment match, not a probability or percentile.
public typealias AlignmentStrength = Double

public enum AlignmentStrengthCategory: String, Sendable, Codable, Equatable {
    case strong
    case moderate
    case weak
    case rejected
    
    public init(strength: AlignmentStrength) {
        switch strength {
        case 0.90...1.00: self = .strong
        case 0.75..<0.90: self = .moderate
        case 0.50..<0.75: self = .weak
        default: self = .rejected
        }
    }
}

public struct TraceAlignmentResult<T: TraceableEvent>: Sendable {
    public let baseRunID: UUID
    public let comparisonRunID: UUID
    public let profileHash: String
    public let engineVersion: String
    public let alignments: [EventAlignment<T>]
    
    // Level 9: Regression Detection
    public let regressionRisk: RegressionRisk
    
    // Verification Proofs (if captureMode == .evidenceOnly)
    public let verificationArtifacts: VerificationArtifacts?
    
    public init(
        baseRunID: UUID,
        comparisonRunID: UUID,
        profileHash: String,
        engineVersion: String,
        alignments: [EventAlignment<T>],
        regressionRisk: RegressionRisk,
        verificationArtifacts: VerificationArtifacts? = nil
    ) {
        self.baseRunID = baseRunID
        self.comparisonRunID = comparisonRunID
        self.profileHash = profileHash
        self.engineVersion = engineVersion
        self.alignments = alignments
        self.regressionRisk = regressionRisk
        self.verificationArtifacts = verificationArtifacts
    }
}

public struct RegressionRisk: Sendable, Equatable {
    public enum Level: String, Sendable, Codable, Equatable {
        case none, low, medium, high
    }
    
    public let level: Level
    public let strength: AlignmentStrength
    public let reasoning: String
    
    public init(level: Level, strength: AlignmentStrength, reasoning: String) {
        self.level = level
        self.strength = strength
        self.reasoning = reasoning
    }
}

public enum AlignmentState: Sendable, Equatable {
    case exactMatch
    case semanticMatch(strength: AlignmentStrength)
    case reordered(originalSequence: UInt64, newSequence: UInt64)
    case ambiguous(optionsCount: Int)
    case added
    case removed
}

public struct EventAlignment<T: TraceableEvent>: Sendable {
    public let state: AlignmentState
    public let baseEvent: TraceEvent<T>?
    public let comparisonEvent: TraceEvent<T>?
    public let explanation: AlignmentExplanation
    public let ambiguousCandidates: [AmbiguousMatch<T>]
    
    public init(state: AlignmentState, baseEvent: TraceEvent<T>?, comparisonEvent: TraceEvent<T>?, explanation: AlignmentExplanation, ambiguousCandidates: [AmbiguousMatch<T>] = []) {
        self.state = state
        self.baseEvent = baseEvent
        self.comparisonEvent = comparisonEvent
        self.explanation = explanation
        self.ambiguousCandidates = ambiguousCandidates
    }
}

public struct AmbiguousMatch<T: TraceableEvent>: Sendable {
    public let event: TraceEvent<T>
    public let strength: AlignmentStrength
    public let explanation: AlignmentExplanation
    
    public init(event: TraceEvent<T>, strength: AlignmentStrength, explanation: AlignmentExplanation) {
        self.event = event
        self.strength = strength
        self.explanation = explanation
    }
}

public struct AlignmentExplanation: Sendable, Equatable {
    public let primaryReason: String
    public let finalScore: Double
    public let rankedEvidence: [HeuristicEvidence]
    
    public init(primaryReason: String, finalScore: Double, rankedEvidence: [HeuristicEvidence]) {
        self.primaryReason = primaryReason
        self.finalScore = finalScore
        // Enforce deterministic sorting by contract
        self.rankedEvidence = AlignmentExecutionContract.canonicalSort(evidence: rankedEvidence)
    }
    
    public static var none: AlignmentExplanation {
        AlignmentExplanation(primaryReason: "No match", finalScore: 0.0, rankedEvidence: [])
    }
}

public struct HeuristicEvidence: Sendable, Equatable {
    public enum Category: String, Sendable, Equatable {
        case typeMatch = "typeMatch"
        case payloadSimilarity = "payloadSimilarity"
        case structuralContext = "structuralContext"
        case temporalLocality = "temporalLocality"
        case semanticEquivalence = "semanticEquivalence"
        case unknown = "unknown"
    }
    
    public let category: Category
    public let scoreContribution: Double
    public let description: String
    
    public init(category: Category, scoreContribution: Double, description: String) {
        self.category = category
        self.scoreContribution = scoreContribution
        self.description = description
    }
    
    static func canonicalSort(evidence: [HeuristicEvidence]) -> [HeuristicEvidence] {
        return evidence.sorted {
            if $0.scoreContribution != $1.scoreContribution {
                return $0.scoreContribution > $1.scoreContribution
            }
            return $0.category.rawValue < $1.category.rawValue
        }
    }
}

extension AlignmentState {
    public var isRemoved: Bool {
        if case .removed = self { return true }
        return false
    }
    
    public var isSemanticMatch: Bool {
        if case .semanticMatch = self { return true }
        return false
    }
    
    public var isExactMatch: Bool {
        if case .exactMatch = self { return true }
        return false
    }
}

public enum AlignmentFinding: Sendable, Equatable {
    case criticalStepRemoved(baseEventIdentifier: String)
    case criticalStepAdded(compEventIdentifier: String)
    case semanticEvolution(baseIdentifier: String, compIdentifier: String)
    case reorderedExecution(eventIdentifier: String, originalSequence: UInt64, newSequence: UInt64)
    case ambiguityDetected(eventIdentifier: String, optionsCount: Int)
    case regressionRisk(RegressionRisk)
}

public struct DecisionTimelineEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let title: String
    public let detail: String
    public let strengthCategory: AlignmentStrengthCategory?
    public let metaEvent: AlignmentMetaEvent?
    
    public init(id: UUID = UUID(), timestamp: Date, title: String, detail: String, strengthCategory: AlignmentStrengthCategory? = nil, metaEvent: AlignmentMetaEvent? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.detail = detail
        self.strengthCategory = strengthCategory
        self.metaEvent = metaEvent
    }
}

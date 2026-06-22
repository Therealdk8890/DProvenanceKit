import Foundation

public enum AlignmentMetaEvent: TraceableEvent, Sendable, Equatable {
    case evaluatedPair(causalParentID: String?, decisionNodeID: String, baseSequence: UInt64, compSequence: UInt64, score: Double)
    case ambiguityThresholdMet(causalParentID: String?, decisionNodeID: String, compSequence: UInt64, score: Double)
    case candidateEvicted(causalParentID: String?, decisionNodeID: String, compSequence: UInt64, reason: String)
    case regressionDetected(causalParentID: String?, decisionNodeID: String, level: String, reasoning: String)
    
    public var typeIdentifier: String {
        switch self {
        case .evaluatedPair: return "evaluatedPair"
        case .ambiguityThresholdMet: return "ambiguityThresholdMet"
        case .candidateEvicted: return "candidateEvicted"
        case .regressionDetected: return "regressionDetected"
        }
    }
    
    public var priority: TracePriority {
        return .structural
    }
    
    public var decisionNodeID: String {
        switch self {
        case .evaluatedPair(_, let nodeID, _, _, _): return nodeID
        case .ambiguityThresholdMet(_, let nodeID, _, _): return nodeID
        case .candidateEvicted(_, let nodeID, _, _): return nodeID
        case .regressionDetected(_, let nodeID, _, _): return nodeID
        }
    }
}

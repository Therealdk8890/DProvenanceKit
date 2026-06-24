import Foundation

public enum TraceEdgeType: String, Codable, Sendable, Equatable {
    case derivedFrom
    case influencedBy
    case generatedFrom
    case verifiedBy
    case correctedBy
    case informed
}

public struct TraceEdge: Sendable, Codable, Equatable {
    public let sourceID: UUID
    public let targetID: UUID
    public let type: TraceEdgeType
    
    public init(sourceID: UUID, targetID: UUID, type: TraceEdgeType) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.type = type
    }
}

import Foundation

public struct TraceGraph<T: TraceableEvent>: Sendable {
    public let nodes: [UUID: TraceEvent<T>]
    public let edges: [TraceEdge]
    
    public init(nodes: [UUID: TraceEvent<T>], edges: [TraceEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

public struct TraceExplanation: Sendable, Equatable {
    public let targetNodeID: UUID
    public let targetNodeSummary: String
    public let informedBy: [String]
    public let derivedFrom: [String]
    
    public init(targetNodeID: UUID, targetNodeSummary: String, informedBy: [String], derivedFrom: [String]) {
        self.targetNodeID = targetNodeID
        self.targetNodeSummary = targetNodeSummary
        self.informedBy = informedBy
        self.derivedFrom = derivedFrom
    }
    
    public func formatted() -> String {
        var lines = [targetNodeSummary, ""]
        
        if !informedBy.isEmpty {
            lines.append("Informed By:")
            for item in informedBy {
                lines.append("- \(item)")
            }
            lines.append("")
        }
        
        if !derivedFrom.isEmpty {
            lines.append("Derived From:")
            for item in derivedFrom {
                lines.append("- \(item)")
            }
            lines.append("")
        }
        
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

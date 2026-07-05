import Foundation

public enum TraceGraphValidationError: Error, CustomStringConvertible {
    case structuralCycleDetected(path: [UUID])
    case invalidEdgeType(UUID)
    case selfReferentialEdge(UUID)
    
    public var description: String {
        switch self {
        case .structuralCycleDetected(let path):
            return "Structural cycle detected in path: \(path.map { $0.uuidString }.joined(separator: " -> "))"
        case .invalidEdgeType(let id):
            return "Invalid edge type for edge: \(id)"
        case .selfReferentialEdge(let id):
            return "Self-referential edge detected: \(id)"
        }
    }
}

/// Validates structural integrity and provenance quality of a trace graph.
public struct TraceGraphValidator<T: TraceableEvent>: Sendable {
    
    public init() {}
    
    /// Validates the structural integrity of the graph (e.g. no cycles in derivedFrom/generatedFrom edges).
    /// - Parameter graph: The graph to validate.
    /// - Throws: `TraceGraphValidationError` if a structural violation is found.
    public func validateStructuralIntegrity(graph: TraceGraph<T>) throws {
        // 1. Self referential edges
        for edge in graph.edges {
            if edge.sourceID == edge.targetID {
                throw TraceGraphValidationError.selfReferentialEdge(edge.sourceID)
            }
        }
        
        // 2. Cycle detection on causal edges (derivedFrom, generatedFrom)
        let causalEdges = graph.edges.filter { $0.type == .derivedFrom || $0.type == .generatedFrom }
        var adjacencyList: [UUID: [UUID]] = [:]
        for edge in causalEdges {
            adjacencyList[edge.sourceID, default: []].append(edge.targetID)
        }
        
        var visited = Set<UUID>()
        var recursionStack = Set<UUID>()
        var path = [UUID]()
        
        func hasCycle(node: UUID) throws {
            visited.insert(node)
            recursionStack.insert(node)
            path.append(node)
            
            if let neighbors = adjacencyList[node] {
                for neighbor in neighbors {
                    if !visited.contains(neighbor) {
                        try hasCycle(node: neighbor)
                    } else if recursionStack.contains(neighbor) {
                        path.append(neighbor)
                        throw TraceGraphValidationError.structuralCycleDetected(path: path)
                    }
                }
            }
            
            recursionStack.remove(node)
            path.removeLast()
        }
        
        for node in graph.nodes.keys {
            if !visited.contains(node) {
                try hasCycle(node: node)
            }
        }
    }
}

public struct TraceGraphProvenanceValidator<T: TraceableEvent>: Sendable {
    
    public let generatedSectionIdentifier: String
    public let factExtractedIdentifier: String
    
    public init(generatedSectionIdentifier: String, factExtractedIdentifier: String) {
        self.generatedSectionIdentifier = generatedSectionIdentifier
        self.factExtractedIdentifier = factExtractedIdentifier
    }
    
    /// Scans a graph for provenance quality violations (anomalies).
    /// - Parameter graph: The fully hydrated TraceGraph to analyze.
    /// - Returns: An array of string descriptions detailing the anomalies found.
    public func detectAnomalies(graph: TraceGraph<T>) -> [String] {
        var anomalies = [String]()
        
        // Find all "generatedSection" nodes
        let generatedSectionNodes = graph.nodes.values.filter { $0.payload.typeIdentifier == generatedSectionIdentifier }
        
        for section in generatedSectionNodes {
            let incomingEdges = graph.edges.filter { $0.targetID == section.id }
            if incomingEdges.isEmpty {
                anomalies.append("Orphan generated section: \(section.id) (\(String(describing: section.payload))). No incoming evidence edges.")
            }
        }
        
        // Find all "factExtracted" nodes
        let factNodes = graph.nodes.values.filter { $0.payload.typeIdentifier == factExtractedIdentifier }
        for fact in factNodes {
            let outgoingEdges = graph.edges.filter { $0.sourceID == fact.id }
            if outgoingEdges.isEmpty {
                anomalies.append("Unused extracted fact: \(fact.id) (\(String(describing: fact.payload))). Extracted but never informed a downstream section.")
            }
        }
        
        return anomalies
    }
}

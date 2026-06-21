import Foundation

public struct TraceRun<T: TraceableEvent>: Sendable {
    public let runID: UUID
    public let contextID: String
    public let events: [TraceEvent<T>]
    
    public init(runID: UUID, contextID: String, events: [TraceEvent<T>]) {
        self.runID = runID
        self.contextID = contextID
        self.events = events
    }
}

public indirect enum TraceQueryNode<T: TraceableEvent>: Sendable {
    case and([TraceQueryNode<T>])
    case or([TraceQueryNode<T>])
    case not(TraceQueryNode<T>)
    
    case contextIDEquals(String)
    case engineNameEquals(String)
    
    case containsStep(String)
    case missingStep(String)
    case sequence([String])
    
    // Temporal operators
    case after(step: String, followedBy: String)
    case before(step: String, precededBy: String)
    
    public func evaluate(run: TraceRun<T>) -> Bool {
        let types = run.events.map { $0.payload.typeIdentifier }
        
        switch self {
        case .and(let nodes):
            guard !nodes.isEmpty else { return true }
            return nodes.allSatisfy { $0.evaluate(run: run) }
        case .or(let nodes):
            guard !nodes.isEmpty else { return true }
            return nodes.contains { $0.evaluate(run: run) }
        case .not(let node):
            return !node.evaluate(run: run)
            
        case .contextIDEquals(let id):
            return run.contextID == id
        case .engineNameEquals(let name):
            return run.events.contains { $0.engineName == name }
            
        case .containsStep(let step):
            return types.contains(step)
            
        case .missingStep(let step):
            return !types.contains(step)
            
        case .sequence(let steps):
            guard !steps.isEmpty else { return true }
            var currentIdx = 0
            for type in types {
                if type == steps[currentIdx] {
                    currentIdx += 1
                    if currentIdx == steps.count { return true }
                }
            }
            return false
            
        case .after(let step, let followedBy):
            if let firstIdx = types.firstIndex(of: step) {
                return types[firstIdx...].contains(followedBy)
            }
            return false
            
        case .before(let step, let precededBy):
            if let firstIdx = types.firstIndex(of: step) {
                return types[..<firstIdx].contains(precededBy)
            }
            return false
        }
    }
}

public struct TraceQueryDSL<T: TraceableEvent>: Sendable {
    public static var schemaVersion: String { "1.0" }
    
    private var rootNode: TraceQueryNode<T>
    
    public init() {
        self.rootNode = .and([])
    }
    
    private init(rootNode: TraceQueryNode<T>) {
        self.rootNode = rootNode
    }
    
    public var ast: TraceQueryNode<T> { rootNode }
    
    public func filter(contextID: String) -> TraceQueryDSL<T> {
        return appendToAnd(.contextIDEquals(contextID))
    }
    
    public func filter(engineName: String) -> TraceQueryDSL<T> {
        return appendToAnd(.engineNameEquals(engineName))
    }
    
    public func requiring(step: String) -> TraceQueryDSL<T> {
        return appendToAnd(.containsStep(step))
    }
    
    public func missing(step: String) -> TraceQueryDSL<T> {
        return appendToAnd(.missingStep(step))
    }
    
    public func requiring(sequence: [String]) -> TraceQueryDSL<T> {
        return appendToAnd(.sequence(sequence))
    }
    
    public func requiring(step: String, followedBy: String) -> TraceQueryDSL<T> {
        return appendToAnd(.after(step: step, followedBy: followedBy))
    }
    
    public func requiring(step: String, precededBy: String) -> TraceQueryDSL<T> {
        return appendToAnd(.before(step: step, precededBy: precededBy))
    }
    
    public func or(_ other: TraceQueryDSL<T>) -> TraceQueryDSL<T> {
        return TraceQueryDSL(rootNode: .or([self.rootNode, other.rootNode]))
    }
    
    private func appendToAnd(_ node: TraceQueryNode<T>) -> TraceQueryDSL<T> {
        if case .and(let existingNodes) = rootNode {
            return TraceQueryDSL(rootNode: .and(existingNodes + [node]))
        } else {
            return TraceQueryDSL(rootNode: .and([rootNode, node]))
        }
    }
}

extension TraceQueryNode: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, nodes, node, id, name, step, steps, followedBy, precededBy
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .and(let nodes):
            try container.encode("and", forKey: .type)
            try container.encode(nodes, forKey: .nodes)
        case .or(let nodes):
            try container.encode("or", forKey: .type)
            try container.encode(nodes, forKey: .nodes)
        case .not(let node):
            try container.encode("not", forKey: .type)
            try container.encode(node, forKey: .node)
        case .contextIDEquals(let id):
            try container.encode("contextIDEquals", forKey: .type)
            try container.encode(id, forKey: .id)
        case .engineNameEquals(let name):
            try container.encode("engineNameEquals", forKey: .type)
            try container.encode(name, forKey: .name)
        case .containsStep(let step):
            try container.encode("containsStep", forKey: .type)
            try container.encode(step, forKey: .step)
        case .missingStep(let step):
            try container.encode("missingStep", forKey: .type)
            try container.encode(step, forKey: .step)
        case .sequence(let steps):
            try container.encode("sequence", forKey: .type)
            try container.encode(steps, forKey: .steps)
        case .after(let step, let followedBy):
            try container.encode("after", forKey: .type)
            try container.encode(step, forKey: .step)
            try container.encode(followedBy, forKey: .followedBy)
        case .before(let step, let precededBy):
            try container.encode("before", forKey: .type)
            try container.encode(step, forKey: .step)
            try container.encode(precededBy, forKey: .precededBy)
        }
    }
}

extension TraceQueryDSL: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rootNode)
    }
}

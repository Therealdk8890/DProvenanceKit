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

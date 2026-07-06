import Foundation

public enum IndexConstraint: Hashable, Sendable {
    case contextID(String)
    case engineName(String)
    case decisionType(String)
}

public struct TraceQueryPlanner: Sendable {
    /// Extracts guaranteed index constraints from an AST.
    /// A constraint is guaranteed if every valid evaluation of the AST MUST satisfy it.
    public static func extractGuaranteedConstraints<T: TraceableEvent>(from ast: TraceQueryNode<T>) -> Set<IndexConstraint> {
        switch ast {
        case .and(let nodes):
            // Union of all guaranteed constraints from children
            var constraints = Set<IndexConstraint>()
            for node in nodes {
                constraints.formUnion(extractGuaranteedConstraints(from: node))
            }
            return constraints
            
        case .or(let nodes):
            // Intersection of guaranteed constraints (must be present in EVERY branch)
            guard let first = nodes.first else { return [] }
            var shared = extractGuaranteedConstraints(from: first)
            for node in nodes.dropFirst() {
                shared.formIntersection(extractGuaranteedConstraints(from: node))
            }
            return shared
            
        case .not:
            // We cannot safely guarantee any presence constraints from a negated branch
            return []
            
        case .contextIDEquals(let id):
            return [.contextID(id)]
            
        case .engineNameEquals(let name):
            return [.engineName(name)]
            
        case .containsStep(let step):
            return [.decisionType(step)]
            
        case .sequence(let steps):
            // A sequence strictly requires ALL of its steps to be present
            return Set(steps.map { .decisionType($0) })
            
        case .after(let step, let followedBy):
            return [.decisionType(step), .decisionType(followedBy)]
            
        case .before(let step, let precededBy):
            return [.decisionType(step), .decisionType(precededBy)]
            
        case .missingStep:
            // A missing step is a negative constraint, not indexable for presence inclusion
            return []

        case .matchingPayload(let step, _):
            // A payload predicate narrowed to `step` still requires an event of that type
            // to exist, so the presence constraint is safe (and lets the index prune
            // candidates before the value predicate runs). An unscoped predicate
            // guarantees nothing structural.
            if let step { return [.decisionType(step)] }
            return []
        }
    }
    
    /// Extracts ALL decision types referenced by the AST, whether required, missing, or sequential.
    /// Used for determining which queries might be impacted by a new event.
    public static func extractAllReferencedDecisionTypes<T: TraceableEvent>(from ast: TraceQueryNode<T>) -> Set<String> {
        switch ast {
        case .and(let nodes), .or(let nodes):
            var types = Set<String>()
            for node in nodes {
                types.formUnion(extractAllReferencedDecisionTypes(from: node))
            }
            return types
            
        case .not(let node):
            return extractAllReferencedDecisionTypes(from: node)
            
        case .containsStep(let step), .missingStep(let step):
            return [step]
            
        case .sequence(let steps):
            return Set(steps)
            
        case .after(let step, let followedBy), .before(let step, let followedBy):
            return [step, followedBy]
            
        case .contextIDEquals, .engineNameEquals:
            return []

        case .matchingPayload(let step, _):
            return step.map { [$0] } ?? []
        }
    }
}

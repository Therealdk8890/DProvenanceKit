import Foundation

public protocol TraceQuerySubscription<T>: Sendable {
    associatedtype T: TraceableEvent
    var queryID: UUID { get }
    var query: TraceQueryDSL<T> { get }
    func onMatch(run: TraceRun<T>)
    func onUpdate(run: TraceRun<T>)
}

public struct QueryState: Sendable {
    public var matchingRuns: Set<UUID> = []
}

public actor LiveTraceQueryEngine<T: TraceableEvent> {
    private var subscriptions: [UUID: any TraceQuerySubscription<T>] = [:]
    private var queryStates: [UUID: QueryState] = [:]
    
    private var impactedQueriesByDecisionType: [String: Set<UUID>] = [:]
    private var globalSubscriptions: Set<UUID> = []
    
    public init() {}
    
    public func register(_ subscription: any TraceQuerySubscription<T>) {
        subscriptions[subscription.queryID] = subscription
        queryStates[subscription.queryID] = QueryState()
        
        let referencedTypes = TraceQueryPlanner.extractAllReferencedDecisionTypes(from: subscription.query.ast)
        if referencedTypes.isEmpty {
            globalSubscriptions.insert(subscription.queryID)
        } else {
            for type in referencedTypes {
                impactedQueriesByDecisionType[type, default: []].insert(subscription.queryID)
            }
        }
    }
    
    public func process(event: TraceEvent<T>, run: TraceRun<T>) async {
        let eventType = event.payload.typeIdentifier
        
        var candidateQueryIDs = impactedQueriesByDecisionType[eventType] ?? []
        candidateQueryIDs.formUnion(globalSubscriptions)
        
        // Safety fallback: if no targeted rules seem impacted, maybe an unexpected rule matters?
        if candidateQueryIDs.isEmpty {
            candidateQueryIDs = Set(subscriptions.keys)
        }
        
        for queryID in candidateQueryIDs {
            guard let subscription = subscriptions[queryID] else { continue }
            var state = queryStates[queryID] ?? QueryState()
            
            let isMatch = subscription.query.ast.evaluate(run: run)
            let previouslyMatched = state.matchingRuns.contains(run.runID)
            
            if isMatch {
                if !previouslyMatched {
                    state.matchingRuns.insert(run.runID)
                    subscription.onMatch(run: run)
                } else {
                    subscription.onUpdate(run: run)
                }
            } else {
                if previouslyMatched {
                    state.matchingRuns.remove(run.runID)
                    // Optionally notify that the run dropped out of the query match.
                }
            }
            
            queryStates[queryID] = state
        }
    }
}

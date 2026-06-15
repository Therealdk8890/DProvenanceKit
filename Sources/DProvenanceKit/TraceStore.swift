import Foundation

public protocol TraceStore<T>: Sendable {
    associatedtype T: TraceableEvent
    func append(_ record: TraceEvent<T>) async throws
    func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>]
}

public actor InMemoryTraceStore<T: TraceableEvent>: TraceStore {
    private var eventsByRunID: [UUID: [TraceEvent<T>]] = [:]
    
    // Indices for Phase 1 candidate narrowing
    private var runByContextID: [String: Set<UUID>] = [:]
    private var runByEngineName: [String: Set<UUID>] = [:]
    private var decisionTypeEvents: [String: [UUID: [Date]]] = [:]
    
    private let liveEngine: LiveTraceQueryEngine<T>?
    
    public init(liveEngine: LiveTraceQueryEngine<T>? = nil) {
        self.liveEngine = liveEngine
    }
    
    public func append(_ record: TraceEvent<T>) async throws {
        eventsByRunID[record.runID, default: []].append(record)
        
        runByContextID[record.contextID, default: []].insert(record.runID)
        runByEngineName[record.engineName, default: []].insert(record.runID)
        
        let type = record.payload.typeIdentifier
        decisionTypeEvents[type, default: [:]][record.runID, default: []].append(record.timestamp)
        
        if let run = getRun(id: record.runID) {
            await liveEngine?.process(event: record, run: run)
        }
    }
    
    public func getRun(id: UUID) -> TraceRun<T>? {
        guard let events = eventsByRunID[id] else { return nil }
        let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        guard let firstEvent = sortedEvents.first else { return nil }
        return TraceRun(runID: id, contextID: firstEvent.contextID, events: sortedEvents)
    }
    
    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        // Phase 1: Candidate Narrowing
        let constraints = TraceQueryPlanner.extractGuaranteedConstraints(from: dsl.ast)
        var candidateRunIDs: Set<UUID>? = nil
        
        for constraint in constraints {
            let matchingIDs: Set<UUID>
            switch constraint {
            case .contextID(let id):
                matchingIDs = runByContextID[id] ?? []
            case .engineName(let name):
                matchingIDs = runByEngineName[name] ?? []
            case .decisionType(let type):
                matchingIDs = Set((decisionTypeEvents[type] ?? [:]).keys)
            }
            
            if let current = candidateRunIDs {
                candidateRunIDs = current.intersection(matchingIDs)
            } else {
                candidateRunIDs = matchingIDs
            }
        }
        
        let finalCandidates = candidateRunIDs ?? Set(eventsByRunID.keys)
        
        // Phase 2: Full AST Evaluation per run
        var matchingRuns: [TraceRun<T>] = []
        for runID in finalCandidates {
            guard let events = eventsByRunID[runID] else { continue }
            // Sort events by timestamp
            let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
            guard let firstEvent = sortedEvents.first else { continue }
            let run = TraceRun(runID: runID, contextID: firstEvent.contextID, events: sortedEvents)
            
            if dsl.ast.evaluate(run: run) {
                matchingRuns.append(run)
            }
        }
        
        return matchingRuns
    }
}

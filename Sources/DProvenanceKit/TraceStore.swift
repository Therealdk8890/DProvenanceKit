import Foundation

public protocol TraceStore<T>: Sendable {
    associatedtype T: TraceableEvent
    func record(_ event: TraceEvent<T>)
    func flush() async throws
    func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>]
    func queryQuarantinedEvents(_ dsl: TraceQueryDSL<T>) async throws -> [TraceEvent<T>]

    /// A by-tier tally of events shed under congestion, for callers that need to
    /// know whether a run's data is complete enough to trust a diff over it.
    var dropStats: TraceDropStats { get }
}

public extension TraceStore {
    /// Stores that cannot shed (e.g. the unbounded in-memory store) report no drops.
    var dropStats: TraceDropStats { .zero }
    
    /// Default implementation for stores that do not quarantine events (e.g., local stores).
    func queryQuarantinedEvents(_ dsl: TraceQueryDSL<T>) async throws -> [TraceEvent<T>] {
        return []
    }
}

/// An in-memory trace store for fast, localized execution and querying.
///
/// Backed by a lock rather than actor isolation so that `record` commits
/// synchronously and in order: once it returns, the event is queryable. `flush`
/// is therefore a no-op barrier, and concurrent records never reorder a run.
///
/// When a `LiveTraceQueryEngine` is supplied, events are delivered to it in FIFO
/// order over an `AsyncStream` drained by a single serial consumer, so live match
/// state stays consistent under concurrent ingestion.
public final class InMemoryTraceStore<T: TraceableEvent>: TraceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var eventsByRunID: [UUID: [TraceEvent<T>]] = [:]

    // Indices for Phase 1 candidate narrowing
    private var runByContextID: [String: Set<UUID>] = [:]
    private var runByEngineName: [String: Set<UUID>] = [:]
    private var decisionTypeEvents: [String: [UUID: [Date]]] = [:]

    private let liveEngine: LiveTraceQueryEngine<T>?
    private let liveContinuation: AsyncStream<(TraceEvent<T>, TraceRun<T>)>.Continuation?
    private let liveTask: Task<Void, Never>?

    public init(liveEngine: LiveTraceQueryEngine<T>? = nil) {
        self.liveEngine = liveEngine

        if let liveEngine {
            var continuation: AsyncStream<(TraceEvent<T>, TraceRun<T>)>.Continuation!
            let stream = AsyncStream<(TraceEvent<T>, TraceRun<T>)>(bufferingPolicy: .unbounded) {
                continuation = $0
            }
            self.liveContinuation = continuation
            self.liveTask = Task {
                // Serial consumer: preserves the order events were recorded in.
                for await (event, run) in stream {
                    await liveEngine.process(event: event, run: run)
                }
            }
        } else {
            self.liveContinuation = nil
            self.liveTask = nil
        }
    }

    deinit {
        liveContinuation?.finish()
        liveTask?.cancel()
    }

    public func record(_ event: TraceEvent<T>) {
        // Snapshot under the same lock so the live engine observes a run that
        // already contains this event, independent of delivery scheduling.
        let snapshot: TraceRun<T>? = lock.withLock {
            eventsByRunID[event.runID, default: []].append(event)
            runByContextID[event.contextID, default: []].insert(event.runID)
            runByEngineName[event.engineName, default: []].insert(event.runID)
            let type = event.payload.typeIdentifier
            decisionTypeEvents[type, default: [:]][event.runID, default: []].append(event.timestamp)
            return (liveContinuation == nil) ? nil : makeRunLocked(id: event.runID)
        }

        if let snapshot {
            liveContinuation?.yield((event, snapshot))
        }
    }

    public func flush() async throws {
        // No-op: `record` commits synchronously, so nothing is pending to drain.
    }

    public func getRun(id: UUID) -> TraceRun<T>? {
        lock.withLock { makeRunLocked(id: id) }
    }

    /// Builds a run snapshot ordered by the authoritative causal clock (`sequence`),
    /// not wall-clock timestamps which can tie at microsecond resolution.
    /// Callers must hold `lock`.
    private func makeRunLocked(id: UUID) -> TraceRun<T>? {
        guard let events = eventsByRunID[id] else { return nil }
        let sortedEvents = events.sorted { $0.sequence < $1.sequence }
        guard let firstEvent = sortedEvents.first else { return nil }
        return TraceRun(runID: id, contextID: firstEvent.contextID, events: sortedEvents)
    }

    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        // Whole query runs under the lock for a consistent snapshot. The body is
        // fully synchronous (no suspension), so the lock is never held across await.
        lock.withLock {
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
                guard let run = makeRunLocked(id: runID) else { continue }
                if dsl.ast.evaluate(run: run) {
                    matchingRuns.append(run)
                }
            }

            return matchingRuns
        }
    }
}

import Foundation

public struct Anomaly: Sendable, Equatable {
    public let runID: UUID
    public let ruleName: String
    public let description: String
    
    public init(runID: UUID, ruleName: String, description: String) {
        self.runID = runID
        self.ruleName = ruleName
        self.description = description
    }
}

public protocol AnomalyRule<T>: Sendable {
    associatedtype T: TraceableEvent
    var name: String { get }
    /// The query that identifies an anomalous run
    var anomalyQuery: TraceQueryDSL<T> { get }
    func describe(run: TraceRun<T>) -> String
}

extension AnomalyRule {
    public func makeAnomaly(run: TraceRun<T>) -> Anomaly {
        return Anomaly(runID: run.runID, ruleName: name, description: describe(run: run))
    }
}

/// A ready-to-use ``AnomalyRule`` that flags runs which reached one reasoning step
/// without a second step that should have justified it — for example, a run that
/// recorded `conflictDetected` but never `documentEvaluated`. This "conclusion
/// without its supporting step" shape is the most common form a reasoning
/// regression takes, packaged so you can detect it without hand-rolling a rule.
///
/// ```swift
/// let rule = MissingSupportRule<MyAIDecision>(
///     name: "UnsupportedConflict",
///     whenPresent: "conflictDetected",
///     isMissing: "documentEvaluated"
/// )
/// let anomalies = try await detector.detectAnomalies(rules: [rule])
/// ```
///
/// The step names are the `typeIdentifier`s of your events, so the rule stays
/// stable across payload refactors. To express a different anomaly shape, conform
/// your own type to ``AnomalyRule`` — this is just the batteries-included starter.
public struct MissingSupportRule<T: TraceableEvent>: AnomalyRule {
    public let name: String
    /// The step whose presence makes the run a candidate.
    public let presentStep: String
    /// The supporting step whose absence makes the run anomalous.
    public let missingStep: String

    public init(name: String, whenPresent presentStep: String, isMissing missingStep: String) {
        self.name = name
        self.presentStep = presentStep
        self.missingStep = missingStep
    }

    public var anomalyQuery: TraceQueryDSL<T> {
        TraceQueryDSL<T>()
            .requiring(step: presentStep)
            .missing(step: missingStep)
    }

    public func describe(run: TraceRun<T>) -> String {
        "Recorded '\(presentStep)' but never '\(missingStep)' — the supporting step is missing."
    }
}

public struct AnomalyDetector<T: TraceableEvent>: Sendable {
    public let store: any TraceStore<T>
    
    public init(store: any TraceStore<T>) {
        self.store = store
    }
    
    public func detectAnomalies(rules: [any AnomalyRule<T>]) async throws -> [Anomaly] {
        var anomalies: [Anomaly] = []
        for rule in rules {
            let anomalousRuns = try await store.queryRuns(rule.anomalyQuery)
            for run in anomalousRuns {
                anomalies.append(rule.makeAnomaly(run: run))
            }
        }
        return anomalies
    }
    
    // Live execution
    public func registerLive(rules: [any AnomalyRule<T>], with liveEngine: LiveTraceQueryEngine<T>) async {
        for rule in rules {
            let subscription = LiveAnomalySubscription(rule: rule)
            await liveEngine.register(subscription)
        }
    }
}

public struct LiveAnomalySubscription<T: TraceableEvent>: TraceQuerySubscription {
    public let queryID = UUID()
    public let rule: any AnomalyRule<T>
    
    public init(rule: any AnomalyRule<T>) {
        self.rule = rule
    }
    
    public var query: TraceQueryDSL<T> {
        return rule.anomalyQuery
    }
    
    public func onMatch(run: TraceRun<T>) {
        let anomaly = rule.makeAnomaly(run: run)
        // In a real system, emit this to an alert stream or notification center
        print("🚨 LIVE ANOMALY DETECTED: [\(anomaly.ruleName)] \(anomaly.description) in run \(anomaly.runID)")
    }
    
    public func onUpdate(run: TraceRun<T>) {
        // Anomaly still present, or changed.
        // Can be ignored or updated.
    }
}

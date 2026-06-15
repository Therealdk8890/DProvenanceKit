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
